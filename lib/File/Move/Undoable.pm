package File::Move::Undoable;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

use Builtin::Logged qw(system);
use File::MoreUtil qw(file_exists l_abs_path);
use File::Trash::Undoable;
use Proc::ChildError qw(explain_child_error);

our %SPEC;

$SPEC{mv} = {
    v           => 1.1,
    summary     => 'Move file/directory using rename/rsync, with undo support',
    description => <<'_',

If moving to the same filesystem, will move using `rename()`. On undo will
restore the old name.

If moving to a different filesystem, will copy to `target` using `rsync` and
then trash `source`. On undo, will trash `target` and restore `source` from
trash.

Fixed state: `source` does not exist and `target` exists. Content or sizes are
not checked; only existence.

Fixable state: `source` exists and `target` doesn't exist.

Unfixable state: `source` does not exist, or both `source` and `target` exist
(unless we are moving to a different filesystem, in which it means an
interrupted transfer and thus fixable).

_
    args        => {
        source => {
            schema => 'str*',
            req    => 1,
            pos    => 0,
        },
        target => {
            schema => 'str*',
            summary => 'Target location',
            description => <<'_',

Note that to avoid ambiguity, you must specify full location instead of just
directory name. For example: mv(source=>'/dir', target=>'/a') will move /dir to
/a and mv(source=>'/dir', target=>'/a/dir') will move /dir to /a/dir.

_
            req    => 1,
            pos    => 1,
        },
        rsync_opts => {
            schema => [array => {of=>'str*', default=>['-a']}],
            summary => 'Rsync options',
            description => <<'_',

By default, `-a` is used. You should not use rsync options that modify or
destroy source, like `--remove-source-files` as it will make recovery of
interrupted move impossible.

_
        },
    },
    features => {
        tx => {v=>2},
        idempotent => 1,
    },
    deps => {
        prog => 'rsync',
    },
};
sub mv {
    require Sys::Filesystem::MountPoint; # a bit heavy

    my %args = @_;

    # TMP, schema
    my $tx_action  = $args{-tx_action} // '';
    my $taid      = $args{-tx_action_id}
        or return [412, "Please specify -tx_action_id"];
    my $dry_run    = $args{-dry_run};
    my $source     = $args{source};
    defined($source) or return [400, "Please specify source"];
    my $target     = $args{target};
    defined($target) or return [400, "Please specify target"];
    my $rsync_opts = $args{rsync_opts} // ['-a'];
    $rsync_opts = [$rsync_opts] unless ref($rsync_opts) eq 'ARRAY';

    my $se      = file_exists($source);
    my $te      = file_exists($target);
    my $asource = l_abs_path($source) or return [400, "Invalid path $source"];
    my $atarget = l_abs_path($target) or return [400, "Invalid path $target"];
    # since path_to_mount_point resolves symlink (sigh), we need to remove the
    # leaf. otherwise: /mnt/sym -> / will cause mount point to become / instead
    # of /mnt
    for ($asource, $atarget) {
        s!/[^/]+\z!! if (-l $_);
    }
    my $mpsource = Sys::Filesystem::MountPoint::path_to_mount_point($asource);
    my $mptarget = Sys::Filesystem::MountPoint::path_to_mount_point($atarget);
    my $same_fs  = $mpsource eq $mptarget;
    if ($same_fs) {
        $log->tracef("Source %s & target %s are on the same filesystem (%s)",
                     $source, $target, $mpsource);
    } else {
        $log->tracef("Source %s and target %s are on different filesystems ".
                         "(%s and %s)", $source, $target, $mpsource, $mptarget);
    }

    if ($tx_action eq 'check_state') {
        return [304, "Source $source already does not exist and ".
                    "target $target exists"] if !$se && $te;
        return [412, "Source $source does not exist"] unless $se;
        return [412, "Target $target already exists"] if $te && $same_fs;

        my @undo;
        if ($te || !$same_fs) {
            unshift @undo, (
                ["File::Trash::Undoable::trash" =>
                     {path=>$target, suffix=>substr($taid,0,8)}],
                ["File::Trash::Undoable::untrash" =>
                     {path=>$source, suffix=>substr($taid,0,8)}],
            );
        } else {
            unshift @undo, (
                [mv => {source=>$target, target=>$source}],
            );
        }

        $log->info("(DRY) ".($te ? "Continue moving" : "Moving").
                       " $source -> $target ...") if $dry_run;
        return [200, "$source needs to be ".
                    ($te ? "continued to be moved":"moved")." to $target",
                undef, {undo_actions=>\@undo}];

    } elsif ($tx_action eq 'fix_state') {
        if ($same_fs) {
            $log->infof("Renaming %s -> %s ...", $source, $target);
            if (rename $source, $target) {
                return [200, "OK"];
            } else {
                return [500, "Can't rename: $!"];
            }
        } else {
            my @cmd = ("rsync", @$rsync_opts, "$source/", "$target/");
            $log->infof("Rsync-ing %s -> %s ...", $source, $target);
            system @cmd;
            return [500, "rsync: ".explain_child_error($?)] if $?;
            return File::Trash::Undoable::trash(
                -tx_action=>'fix_state',
                path=>$source, suffix=>substr($taid,0,8));
        }
    }
    [400, "Invalid -tx_action"];
}

1;
# ABSTRACT:

=head1 FAQ

=head2 Why do you use rsync? Why not, say, File::Copy::Recursive?

With C<rsync>, we can continue interrupted transfer. We need this ability for
recovery. Also, C<rsync> can handle hardlinks and preservation of ownership,
something which L<File::Copy::Recursive> currently does not do. And, being
implemented in C, it might be faster when processing large files/trees.


=head1 SEE ALSO

L<Setup>

L<Rinci::Transaction>

=cut
