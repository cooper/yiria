#!/usr/bin/perl
# Copyright (c) 2010-12, Mitchell Cooper
package utils;

use warnings;
use strict;
use feature qw[switch say];

our %GV;

# fetch a configuration file

sub conf {
    my ($sec, $key) = @_;
    return $main::conf->get($sec, $key);
}

sub lconf { # for named blocks
    my ($block, $sec, $key) = @_;
    return $main::conf->get([$block, $sec], $key);
}

sub conn {
    my ($sec, $key) = @_;
    return $main::conf->get(['connect', $sec], $key);
}

# log errors/warnings

sub log2 {
    return if !$main::NOFORK  && defined $main::PID;
    my $line = shift;
    my $sub = (caller 1)[3];
    say(time.q( ).($sub && $sub ne '(eval)' ? "$sub():" : q([).(caller)[0].q(])).q( ).$line)
}

# log and exit

sub fatal {
    my $line = shift;
    my $sub = (caller 1)[3];
    log2(($sub ? "$sub(): " : q..).$line);
    exit(shift() ? 0 : 1)
}

# remove a prefixing colon

sub col {
    my $string = shift;
    $string =~ s/^://;
    return $string
}

# find an object by it's id (server, user) or channel name
sub global_lookup {
    my $id = shift;
    my $server = server::lookup_by_id($id);
    my $user   = user::lookup_by_id($id);
    my $chan   = channel::lookup_by_name($id);
    return $server ? $server : ( $user ? $user : ( $chan ? $chan : undef ) )
}

# remove leading and trailing whitespace

sub trim {
    my $string = shift;
    $string =~ s/\s+$//;
    $string =~ s/^\s+//;
    return $string
}

# check if a nickname is valid
sub validnick {
    my $str   = shift;
    my $limit = conf('limit', 'nick');

    # valid characters
    return if (length $str < 1 ||
      length $str > $limit ||
      ($str =~ m/^\d/) ||
      $str =~ m/[^A-Za-z-0-9-\[\]\\\`\^\|\{\}\_]/);

    # success
    return 1

}

# check if a channel name is valid
sub validchan {
    my $name = shift;
    return if length $name > conf('limit', 'channelname');
    return unless $name =~ m/^#/;
    return 1
}

# match a host to a list
sub match {
    my ($mask, @list) = @_;
    $mask = lc $mask;
    my @aregexps;

    # convert IRC expression to Perl expression.
    @list = map {
        $_ = "\Q$_\E";  # escape all non-alphanumeric characters.
        s/\\\?/\./g;    # replace "\?" with "."
        s/\\\*/\.\*/g;  # replace "\*" with ".*"
        s/\\\@/\@/g;    # replace "\@" with "@"
        s/\\\!/\!/g;    # replace "\!" with "!"
        lc
    } @list;

    # success
    return 1 if grep { $mask =~ m/^$_$/ } @list;

    # no matches
    return

}

sub lceq {
    lc shift eq lc shift
}

# chop a string to its limit as the config says
sub cut_to_limit {
    my ($limit, $string) = (conf('limit', shift), shift);
    return $string unless defined $limit;
    my $overflow = length($string) - $limit;
    $string = substr $string, 0, -$overflow if length $string > $limit;
    return $string
}

# encrypt something
sub crypt {
    my ($what, $crypt) = @_;

    # no do { given { 
    # compatibility XXX
    my $func = 'die';
    given ($crypt) {
        when ('sha1')   { $func = 'Digest::SHA::sha1_hex'   }
        when ('sha224') { $func = 'Digest::SHA::sha224_hex' }
        when ('sha256') { $func = 'Digest::SHA::sha256_hex' }
        when ('sha384') { $func = 'Digest::SHA::sha384_hex' }
        when ('sha512') { $func = 'Digest::SHA::sha512_hex' }
        when ('md5')    { $func = 'Digest::MD5::md5_hex'    }
    }

    $what    =~ s/'/\\'/g;
    my $eval =  "$func('$what')";

    # use eval to prevent crash if failed to load the module
    $what = eval $eval;

    if (not defined $what) {
        log2("couldn't crypt to $crypt. you probably forgot to load it. $@");
        return $what;
    }

    return $what
}

# GV

sub gv {
    # can't use do{given{
    # compatibility with 5.12 XXX
    given (scalar @_) {
        when (1) { return $GV{+shift}                 }
        when (2) { return $GV{+shift}{+shift}         }
        when (3) { return $GV{+shift}{+shift}{+shift} }
    }
    return
}

sub set ($$) {
    my $set = shift;
    if (uc $set eq $set) {
        log2("can't set $set");
        return;
    }
    $GV{$set} = shift
}

# for configuration values

sub on  () { 1 }
sub off () { 0 }

sub import {
    my $package = caller;
    no strict 'refs';
    *{$package.'::'.$_} = *{__PACKAGE__.'::'.$_} foreach @_[1..$#_]
}

sub ircd_LOAD {
    # savor GV and conf
    ircd::reloadable(sub {
        $main::TMP_GV   = \%GV;
    }, sub {
        %GV   = %{$main::TMP_GV};
        undef $main::TMP_CONF;
        undef $main::TMP_GV
    })
}

# EVENTS

# fire an event handler.
sub fire_event {
    my ($event, @args) = @_;
    
    # TODO: fire events on specific objects
    
    # For example, channel:user_joined should fire on the
    # channel object itself as well as the main evented object.
    
    $main::eo->fire_event("juno.$event" => @args);
}

# register an event handler.
sub register_event {
    my $event = shift;
    $main::eo->register_event("juno.$event", @_);
}

# delete an event handler.
sub delete_event {
    my ($event, $handlerID) = @_;
    $main::eo->delete_event("juno.$event", $handlerID);
}

1
