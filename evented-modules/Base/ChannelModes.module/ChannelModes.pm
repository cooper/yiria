# Copyright (c) 2014, Mitchell Cooper
#
# @name:            "Base::ChannelModes"
# @version:         ircd->VERSION
# @package:         "M::Base::ChannelModes"
#
# @author.name:     "Mitchell Cooper"
# @author.website:  "https://github.com/cooper"
#
package M::Base::ChannelModes;

use warnings;
use strict;
use 5.010;

my ($api, $mod);

sub init {
    
    # register methods.
    $mod->register_module_method(
        register_channel_mode_block => \&register_channel_mode_block
    ) or return;
    
    # module unload event.
    $api->on(unload_module => \&unload_module) or return;
    
    return 1;
}

sub register_channel_mode_block {
    my ($mod, %opts) = @_;
    
    # make sure all required options are present.
    foreach my $what (qw|name code|) {
        next if exists $opts{$what};
        $opts{name} ||= 'unknown';
        # TODO: log.
        return;
    }
    
    # register the mode block.
    $::pool->register_channel_mode_block(
        $opts{name},
        $mod->{name},
        $opts{code}
    );
    
    $mod->list_store_add('channel_modes', $opts{name});
}

sub unload_module {
    my ($event, $mod) = @_;
    # TODO: log
    
    # delete all mode blocks.
    $::pool->delete_channel_mode_block($_, $mod->{name})
      foreach $mod->list_store_items('channel_modes');
    
    return 1;
}

$mod