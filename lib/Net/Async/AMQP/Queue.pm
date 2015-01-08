package Net::Async::AMQP::Queue;
$Net::Async::AMQP::Queue::VERSION = '0.020';
use strict;
use warnings;

use parent qw(IO::Async::Notifier);

=head1 NAME

Net::Async::AMQP - provides client interface to AMQP using L<IO::Async>

=head1 VERSION

version 0.020

=head1 SYNOPSIS

 use IO::Async::Loop;
 use Net::Async::AMQP;
 my $loop = IO::Async::Loop->new;
 $loop->add(my $amqp = Net::Async::AMQP->new);
 $amqp->connect(
   host => 'localhost',
   username => 'guest',
   password => 'guest',
   on_connected => sub {
   }
 );

=head1 DESCRIPTION

=cut

use Future;
use curry::weak;
use Class::ISA ();
use Scalar::Util qw(weaken);

use Net::Async::AMQP;

=head1 ACCESSORS

=cut

sub configure {
	my ($self, %args) = @_;
	for(grep exists $args{$_}, qw(amqp)) {
		Scalar::Util::weaken($self->{$_} = delete $args{$_})
	}
	for(grep exists $args{$_}, qw(future channel)) {
		$self->{$_} = delete $args{$_};
	}
    $self->SUPER::configure(%args);
}

sub amqp { shift->{amqp} }

sub future { shift->{future} }

sub queue_name {
    my $self = shift;
    return $self->{queue_name} unless @_;
    $self->{queue_name} = shift;
    $self
}

sub channel { shift->{channel} }

=head1 METHODS

=cut

=head1 PROXIED METHODS - Net::Async::AMQP

=cut

sub write { shift->amqp->write(@_) }

=head1 PROXIED METHODS - Net::Async::AMQP::Channel

=cut

sub send_frame { shift->channel->send_frame(@_) }
sub push_pending { shift->channel->push_pending(@_) }
sub closure_protection { shift->channel->closure_protection(@_) }

=head1 METHODS

=cut

sub listen {
    my $self = shift;
    my %args = @_;

    # Attempt to bind after we've successfully declared the exchange.
    my $f = $self->future->then(sub {
        my $f = $self->loop->new_future;
        $self->debug_printf("Attempting to listen for events on queue [%s]", $self->queue_name);

        my $frame = Net::AMQP::Protocol::Basic::Consume->new(
            queue        => Net::AMQP::Value::String->new($self->queue_name),
            consumer_tag => (exists $args{consumer_tag} ? Net::AMQP::Value::String->new($args{consumer_tag}) : ''),
            no_local     => 0,
            no_ack       => ($args{ack} ? 0 : 1),
            exclusive    => 0,
            ticket       => 0,
            nowait       => 0,
        );
        $self->push_pending(
            'Basic::ConsumeOk' => (sub {
                my ($amqp, $frame) = @_;
				my $ctag = $frame->method_frame->consumer_tag;
				$self->channel->bus->invoke_event(
					listener_start => $ctag
				);

				# If we were cancelled before we received the OK response,
				# that's mildly awkward - we need to cancel the consumer,
				# note that messages may be delivered in the interim.
				if($f->is_cancelled) {
					$self->adopt_future(
						$self->cancel(
							consumer_tag => $ctag
						)->set_label(
							"Cancel $ctag"
						)->on_fail(sub {
							# We should report this, but where to?
							$self->debug_printf("Failed to cancel listener %s", $ctag);
						})->else(sub {
							Future->wrap
						})
					)
				}
                $f->done($self => $ctag) unless $f->is_ready;
            })
        );
		$self->closure_protection($f);
        $self->send_frame($frame);
        $f;
    });
	$self->adopt_future($f->else_done);
	$f
}

=head2 cancel

Cancels the given consumer.

=cut

sub cancel {
    my $self = shift;
    my %args = @_;

    # Attempt to bind after we've successfully declared the exchange.
	my $f = $self->future->then(sub {
		my $f = $self->loop->new_future;
		$self->debug_printf("Attempting to cancel consumer [%s]", $args{consumer_tag});

		my $frame = Net::AMQP::Protocol::Basic::Cancel->new(
			consumer_tag => Net::AMQP::Value::String->new($args{consumer_tag}),
			nowait       => 0,
		);
		$self->push_pending(
			'Basic::CancelOk' => (sub {
				my ($amqp, $frame) = @_;
				my $ctag = $frame->method_frame->consumer_tag;
				$self->channel->bus->invoke_event(
					listener_stop => $ctag
				);
				$f->done($self => $ctag) unless $f->is_cancelled;
			})
		);
		$self->closure_protection($f);
		$self->send_frame($frame);
		$f;
	});
    $self->adopt_future($f->else_done);
	$f
}

sub bind_exchange {
    my $self = shift;
    my %args = @_;
    die "No exchange specified" unless exists $args{exchange};

    # Attempt to bind after we've successfully declared the exchange.
	my $f = $self->future->then(sub {
		my $f = $self->loop->new_future;
		$self->debug_printf("Binding queue [%s] to exchange [%s] with rkey [%s]", $self->queue_name, $args{exchange}, $args{routing_key} // '(none)');

		my $frame = Net::AMQP::Frame::Method->new(
			method_frame => Net::AMQP::Protocol::Queue::Bind->new(
				queue       => Net::AMQP::Value::String->new($self->queue_name),
				exchange    => Net::AMQP::Value::String->new($args{exchange}),
				(exists($args{routing_key}) ? ('routing_key' => Net::AMQP::Value::String->new($args{routing_key})) : ()),
				ticket      => 0,
				nowait      => 0,
			)
		);
		$self->push_pending(
			'Queue::BindOk' => [ $f, $self ],
		);
		$self->closure_protection($f);
		$self->send_frame($frame);
		$f
	});
	$self->adopt_future($f->else_done);
	$f
}

=head2 delete

Deletes this queue.

=cut

sub delete : method {
    my $self = shift;
    my %args = @_;

	my $f = $self->future->then(sub {
		my $f = $self->loop->new_future;
		$self->debug_printf("Deleting queue [%s]", $self->queue_name);

		my $frame = Net::AMQP::Frame::Method->new(
			method_frame => Net::AMQP::Protocol::Queue::Delete->new(
				queue       => Net::AMQP::Value::String->new($self->queue_name),
				nowait      => 0,
			)
		);
		$self->push_pending(
			'Queue::DeleteOk' => [ $f, $self ],
		);
		$self->closure_protection($f);
		$self->send_frame($frame);
		$f
	});
	$self->adopt_future($f->else_done);
	$f
}

1;

__END__

=head1 AUTHOR

Tom Molesworth <cpan@perlsite.co.uk>

=head1 LICENSE

Licensed under the same terms as Perl itself, with additional licensing
terms for the MQ spec to be found in C<share/amqp0-9-1.extended.xml>
('a worldwide, perpetual, royalty-free, nontransferable, nonexclusive
license to (i) copy, display, distribute and implement the Advanced
Messaging Queue Protocol ("AMQP") Specification').
