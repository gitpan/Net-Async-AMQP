use strict;
use warnings;
use Test::More;
use Test::MemoryGrowth;
use Test::Refcount;

use Future::Utils;
use IO::Async::Loop;
use Net::Async::AMQP::ConnectionManager;

my $loop = IO::Async::Loop->new;

# Set up a connection manager with our MQ server details
my $cm = Net::Async::AMQP::ConnectionManager->new;
$loop->add($cm);
$cm->add(
  host  => 'localhost',
  user  => 'guest',
  pass  => 'guest',
  vhost => '/',
);

my @seen;
(Future::Utils::fmap_void {
	my $wch;
	$cm->request_channel->then(sub {
		my $ch = shift;
		Scalar::Util::weaken($wch = $ch);
		ok($ch->id, 'have a channel');
		# is_refcount($ch, 6, 'we have only 6 copies of the channel proxy');
		$ch->exchange_declare(
			exchange => 'test_exchange',
			type     => 'fanout',
		)
	})->on_done(sub {
		is($wch, undef, 'channel proxy has disappeared');
		pass('succeeded')
	});
} foreach => [1..8], concurrent => 4)->then(sub {
	$cm->shutdown;
})->get;

done_testing;

