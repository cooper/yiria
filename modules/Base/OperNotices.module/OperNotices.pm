# Copyright (c) 2016, Mitchell Cooper
#
# @name:            "Base::OperNotices"
# @package:         "M::Base::OperNotices"
#
# @depends.modules+ "API::Methods"
#
# @author.name:     "Mitchell Cooper"
# @author.website:  "https://github.com/cooper"
#
package M::Base::OperNotices;

use warnings;
use strict;
use 5.010;

our ($api, $mod, $pool);

sub init {

    # register methods.
    $mod->register_module_method('register_oper_notice') or return;

    # module events.
    $api->on('module.unload' => \&on_unload, 'void.oper.notices');
    $api->on('module.init'   => \&module_init,   '%oper_notices');

    return 1;
}

sub register_oper_notice {
    my ($mod, $event, %opts) = @_;

    # make sure all required options are present.
    foreach my $what (qw|name format|) {
        next if exists $opts{$what};
        $opts{name} ||= 'unknown';
        L("Oper notice '$opts{name}' does not have '$what' option");
        return;
    }

    # register the notice.
    $opts{name} = lc $opts{name};
    $pool->register_notice(
        $mod->name,
        $opts{name},
        $opts{format} // $opts{code}
    ) or return;

    D("'$opts{name}' registered");
    $mod->list_store_add('oper_notices', $opts{name});
    return 1;
}

sub on_unload {
    my ($mod, $event) = @_;
    $pool->delete_notice($mod->name, $_) foreach $mod->list_store_items('oper_notices');
    return 1;
}

# a module is being initialized.
sub module_init {
    my $mod = shift;
    my %notices = $mod->get_symbol('%oper_notices');
    $mod->register_oper_notice(
        name   => $_,
        format => $notices{$_}
    ) || return foreach keys %notices;
    return 1;
}

$mod
