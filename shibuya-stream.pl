#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use utf8;

use Coro;
use Coro::Channel;
use Coro::AnyEvent;

use IO::Handle::Util qw(io_from_getline);

use AnySan;
use AnySan::Provider::IRC;
use AnySan::Provider::Twitter;

use Plack::Runner;
use Plack::Request;
use Plack::Response;

use Config::Pit;
use Encode;
use JSON;
use URI::Escape;

my $keyword = $ARGV[0] || 'shibuyapm';

my $config = pit_get("example.com", require => {
    consumer_key    => 'your twitter consumer_key',
    consumer_secret => 'your twitter consumer_secret',
    token           => 'your twitter access_token',
    token_secret    => 'your twitter access_token_secret',
});

my $twitter = twitter
    consumer_key    => $config->{consumer_key},
    consumer_secret => $config->{consumer_secret},
    token           => $config->{token},
    token_secret    => $config->{token_secret},
    method          => 'filter',
    track           => $keyword,
    ;

my @queue;

AnySan->register_listener(
    streamer => {
        event => 'timeline',
        cb    => sub {
            my $receive = shift;
            return unless $receive->provider eq 'twitter';
            return unless $receive->from_nickname && $receive->message;
            return if $receive->message =~ /^RT /;
            my $msg = sprintf '%s: %s', $receive->from_nickname, encode( utf8 => $receive->message );
            print STDOUT "$msg\n";
            for my $coro (@queue) {
                $coro->put($receive);
            }
        },
    },
);

my $boundary = '|||';
my $app = sub {
    my $req = Plack::Request->new(shift);
    if ($req->path eq '/') {
        open my $fh, '<', './index.html';
        my $html = do { local $/; <$fh> };
        $html =~ s/\$keyword/$keyword/g;
        my $res = Plack::Response->new(200);
        $res->body($html);
        return $res->finalize;
    } elsif ($req->path eq '/js/DUI.js') {
        open my $fh, '<', './DUI.js';
        my $res = Plack::Response->new(200);
        $res->body($fh);
        return $res->finalize;
    } elsif ($req->path eq '/js/Stream.js') {
        open my $fh, '<', './Stream.js';
        my $res = Plack::Response->new(200);
        $res->body($fh);
        return $res->finalize;
    } elsif ($req->path eq '/js/jquery.js') {
        open my $fh, '<', './jquery-1.4.2.min.js';
        my $res = Plack::Response->new(200);
        $res->body($fh);
        return $res->finalize;
    } elsif ($req->path eq '/stream') {
        my $coro = Coro::Channel->new;
        push @queue, $coro;
        my $count = 1;
        my $body = io_from_getline sub {
            if ($count) {
                $count--;
                return "--$boundary\n"
            }
            my $receive = $coro->get;
            if ($receive->message) {
                my $ret = "Content-Type: application/javascript\n";
                $ret .= to_json({
                    nickname   => $receive->from_nickname,
                    message    => encode( utf8 => $receive->message ),
                    icon_url   => $receive->attribute('icon_url'),
                    created_at => $receive->attribute('created_at'),
                });
                $ret .= "\n--$boundary\n";
                return $ret;
            } else {
                return '';
            }
        };
        return [ 200, ['Content-Type' => qq{multipart/mixed; boundary="$boundary"} ], $body ];
    } else {
        my $res = Plack::Response->new(404);
        $res->body('not found');
        return $res->finalize;
    }
};

my $runner = Plack::Runner->new(
    env     => 'development',
    server  => 'Corona',
    options => [
        host => '0.0.0.0',
        port => 9999,
    ],
);
$runner->run( $app );
AnySan->run;
