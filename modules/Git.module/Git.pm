# Copyright (c) 2016, Mitchell Cooper
#
# @name:            "Git"
# @package:         "M::Git"
# @description:     "git repository management"
#
# @depends.bases+   'UserCommands', 'OperNotices'
# @depends.modules+ 'JELP::Base'
#
# @author.name:     "Mitchell Cooper"
# @author.website:  "https://github.com/cooper"
#
package M::Git;

use warnings;
use strict;
use 5.010;

use IO::Async::Process;
use utils qw(col gnotice trim);

our ($api, $mod, $pool, $me);

# UPDATE user command
our %user_commands = (
    CHECKOUT => {
        desc   => 'switch branches or commits in the IRCd git repository',
        params => '-oper(checkout) * *(opt)',
        code   => \&ucmd_checkout
    },
    UPDATE => {
        desc   => 'update the IRCd git repository',
        params => '-oper(update) *(opt)',
        code   => \&ucmd_update
    }
);

# oper notices
our %oper_notices = (
    checkout_fail   => 'Checkout \'%s\' on %s by %s failed',
    checkout        => 'Checked out \'%s\' version %s on %s by %s',
    update_fail     => 'Update to %s git reposity by %s failed (%s)',
    update          => '%s git repository updated to version %s successfully by %s'
);

sub init {

    # allow UPDATE to work remotely.
    $mod->register_global_command(name => $_) or return
        for qw(checkout update);

    return 1;
}

# CHECKOUT user command
sub ucmd_checkout {
    my ($user, $event, $server_mask_maybe, $point) = @_;

    # server parameter?
    if (!defined $point) {
        $point = $server_mask_maybe;
        undef $server_mask_maybe;
    }
    if (length $server_mask_maybe) {
        my @servers = $pool->lookup_server_mask($server_mask_maybe);

        # no priv.
        if (!$user->has_flag('gcheckout')) {
            $user->numeric(ERR_NOPRIVILEGES => 'gcheckout');
            return;
        }

        # no matches.
        if (!@servers) {
            $user->numeric(ERR_NOSUCHSERVER => $server_mask_maybe);
            return;
        }

        # use forward_global_command() to send it out.
        my $matched = server::protocol::forward_global_command(
            \@servers,
            ircd_checkout => $user, $server::protocol::INJECT_SERVERS
        ) if @servers;
        my %matched = $matched ? %$matched : ();

        # if $me is not in %done, we're not reloading locally.
        return 1 if !$matched{$me};

    }

    # git checkout
    command([ 'git', 'checkout', $point ], undef,

        # success
        sub { git_checkout_succeeded($user, $event, $point) },

        # failure
        sub {
            gnotice($user, checkout_fail =>
                $point, $me->name, $user->notice_info
            );
        }

    );

    return 1;
}

# UPDATE user command
sub ucmd_update {
    my ($user, $event, $server_mask_maybe) = @_;

    # server parameter?
    if (length $server_mask_maybe) {
        my @servers = $pool->lookup_server_mask($server_mask_maybe);

        # no priv.
        if (!$user->has_flag('gupdate')) {
            $user->numeric(ERR_NOPRIVILEGES => 'gupdate');
            return;
        }

        # no matches.
        if (!@servers) {
            $user->numeric(ERR_NOSUCHSERVER => $server_mask_maybe);
            return;
        }

        # use forward_global_command() to send it out.
        my $matched = server::protocol::forward_global_command(
            \@servers,
            ircd_update => $user, $server::protocol::INJECT_SERVERS
        ) if @servers;
        my %matched = $matched ? %$matched : ();

        # if $me is not in %done, we're not reloading locally.
        return 1 if !$matched{$me};

    }

    # git pull
    command([ 'git', 'pull' ], undef,

        # success
        sub {
            git_pull_succeeded($user, $event);
        },

        # error
        sub {
            my $error = shift;
            my @lines = split /\n/, $error;
            $user->server_notice(update => "[$$me{name}] Errors (pull): $_")
            foreach @lines;
            gnotice($user, update_fail =>
                $me->name, $user->notice_info, 'git pull'
            );

            # handle Evented API Engine manifest conflicts
            deal_with_manifest($user, $event) if index($error, '.json') != -1;

        }
    );
}

# after git pull, run git submodule update --init
sub git_pull_succeeded {
    my ($user, $event) = @_;

    # git submodule update --init
    command(['git', 'submodule', 'update', '--init'], undef,

        # success
        sub {
            git_submodule_succeeded($user, $event);
        },

        # error
        sub {
            my @lines = split /\n/, shift;
            $user->server_notice(update => "[$$me{name}] Errors (submodule): $_")
                foreach @lines;
            gnotice(update_fail => $me->name,
                $user->notice_info, 'git submodule update --init'
            );
        }
    );
}

# after git checkout, use git describe to get a tag
sub git_checkout_succeeded {
    my ($user, $event, $point) = @_;
    my $desc;
    command(['git', 'describe'],
        sub { $desc = shift                          },
        sub { checkout_finish($user, $point, $desc)  },
        sub { checkout_finish($user, $point)         }
    );
}

# after git describe, tell opers that it succeeded
sub checkout_finish {
    my ($user, $point, $desc) = @_;
    my $version = ircd::get_version();
    if (length $desc) {
        $desc = trim($desc);
        $version = "$version ($desc)";
    }
    gnotice($user, checkout => $point, $version, $me->name, $user->notice_info);
}

# after git submodule, use git describe to get a tag
sub git_submodule_succeeded {
    my ($user, $event) = @_;
    my $desc;
    command(['git', 'describe'],
        sub { $desc = shift                },
        sub { update_finish($user, $desc)  },
        sub { update_finish($user)         }
    );
}

# after git describe, tell opers that it succeeded
sub update_finish {
    my ($user, $desc) = @_;
    my $version = ircd::get_version();
    if (length $desc) {
        $desc = trim($desc);
        $version = "$version ($desc)";
    }
    gnotice($user, update => $me->name, $version, $user->notice_info);
}


# handle Evented API Engine manifest conflicts
sub deal_with_manifest {
    my ($user, $event) = @_;

    # if this server is in developer mode, we can't do much about it.
    return if $api->{developer};

    # otherwise, dispose of the manifests for git to replace.
    # then retry from the beginning.
    command('rm $(find . | grep \'\.json\' | xargs)', undef, sub {
        ucmd_update($user, $event, $me->{name});
    });

}

# git command wrapper
sub command {
    my ($command, $stdout_cb, $finish_cb, $error_cb) = @_;
    my $command_name = ref $command eq 'ARRAY' ? join ' ', @$command : $command;
    my $error_msg    = '';
    my $process      = IO::Async::Process->new(
        command => $command,

        # call stdout callback for each line
        stdout => {
            on_read => sub {
                my ($stream, $buffref) = @_;
                while ($$buffref =~ s/^(.*)\n//) {
                    D("$command_name: $1");
                    $stdout_cb->($1) if $stdout_cb;
                }
            }
        },

        # add stderr to error message
        stderr => {
            on_read => sub {
                my ($stream, $buffref) = @_;
                while ($$buffref =~ s/^(.*)\n//) {
                    L("$command_name error: $1");
                    $error_msg .= "$$buffref\n";
                }
            }
        },

        on_finish => sub {
            my ($self, $exitcode) = @_;

            # error
            if ($exitcode) {
                L("Exception: $command_name: $error_msg");
                $error_cb->($error_msg) if $error_cb;
                return;
            }

            D("Finished: $command_name");
            $finish_cb->() if $finish_cb;
        }
    );
    D("Running: $command_name");
    $::loop->add($process);
}

$mod
