package Net::Async::AMQP::Queue;
$Net::Async::AMQP::Queue::VERSION = '0.002';
use strict;
use warnings;
use parent qw(Mixin::Event::Dispatch);

=head1 NAME

Net::Async::AMQP - provides client interface to AMQP using L<IO::Async>

=head1 VERSION

version 0.002

=head1 SYNOPSIS

 use IO::Async::Loop;
 use Net::Async::AMQP;
 my $amqp = Net::Async::AMQP->new(loop => my $loop = IO::Async::Loop->new);
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
use Closure::Explicit qw(callback);
use Class::ISA ();
use Data::Dumper;
use Scalar::Util qw(weaken);

use Net::Async::AMQP;

use constant DEBUG => Net::Async::AMQP->DEBUG;

=head1 ACCESSORS

=cut

sub loop { shift->amqp->loop }

sub amqp { shift->{amqp} }

sub future { shift->{future} }

sub queue_name {
    my $self = shift;
    return $self->{queue_name} unless @_;
    $self->{queue_name} = shift;
    $self
}

sub channel {
    my $self = shift;
    return $self->{channel} unless @_;
    Scalar::Util::weaken($self->{channel} = shift);
    $self
}

=head1 METHODS

=cut

sub new {
    my $class = shift;
    my $self = bless { @_ }, $class;
    Scalar::Util::weaken($_) for @{$self}{qw/amqp channel/};
    $self
}

=head1 PROXIED METHODS

The following methods are proxied to the L<Net::Async::AMQP> class.

=cut

sub write { shift->amqp->write(@_) }
sub send_frame { shift->amqp->send_frame(@_) }
sub push_pending { shift->amqp->push_pending(@_) }

sub listen {
    my $self = shift;
    my %args = @_;

    # Attempt to bind after we've successfully declared the exchange.
    $self->future->then(callback {
        my $self = shift;
        my $f = $self->loop->new_future;
        warn "Attempting to listen for events on queue [" . $self->queue_name . "]\n" if DEBUG;

        my $frame = Net::AMQP::Protocol::Basic::Consume->new(
            queue        => $self->queue_name,
            consumer_tag => '',
            no_local     => 0,
            no_ack       => ($args{ack} ? 0 : 1),
            exclusive    => 0,
            ticket       => 0,
            nowait       => 0,
        );
        $self->push_pending(
            'Basic::ConsumeOk' => (callback {
                my ($self, $amqp, $frame) = @_;
                $f->done($self => $frame->method_frame->consumer_tag) unless $f->is_cancelled;
				weaken $f;
            } weaken => [qw($self)],
              allowed => [qw($f)])
        );
        $self->send_frame($frame, channel => $self->channel->id);
        $f;
    } weaken => [qw($self)],
      allowed => [qw(%args)]);
}

=head2 cancel

Cancels the given consumer.

=cut

sub cancel {
    my $self = shift;
    my %args = @_;

    # Attempt to bind after we've successfully declared the exchange.
    $self->future->then(callback {
        my $self = shift;
        my $f = $self->loop->new_future;
        warn "Attempting to cancel consumer [" . $args{consumer_tag} . "]\n" if DEBUG;

        my $frame = Net::AMQP::Protocol::Basic::Cancel->new(
            consumer_tag => $args{consumer_tag},
            nowait       => 0,
        );
        $self->push_pending(
            'Basic::CancelOk' => (callback {
                my ($self, $amqp, $frame) = @_;
                $f->done($self => $frame->method_frame->consumer_tag) unless $f->is_cancelled;
				weaken $f;
            } weaken => [qw($self)],
              allowed => [qw($f)])
        );
        $self->send_frame($frame, channel => $self->channel->id);
        $f;
    } weaken => [qw($self)],
      allowed => [qw(%args)]);
}

sub bind_exchange {
    my $self = shift;
    my %args = @_;
    die "No exchange specified" unless exists $args{exchange};

    # Attempt to bind after we've successfully declared the exchange.
    $self->future->then(callback {
        my $self = shift;
        my $f = $self->loop->new_future;
        warn "Attempting to bind our queue [" . $self->queue_name . "] to exchange [" . $args{exchange} . "]" if DEBUG;

        my $frame = Net::AMQP::Frame::Method->new(
            channel => $self->channel->id,
            method_frame => Net::AMQP::Protocol::Queue::Bind->new(
                queue       => $self->queue_name,
                exchange    => $args{exchange},
                (exists($args{routing_key}) ? ('routing_key' => $args{routing_key}) : ()),
                ticket      => 0,
                nowait      => 0,
            )
        );
        $self->push_pending(
            'Queue::BindOk' => callback {
                my $self = shift;
                $f->done($self) unless $f->is_ready;
				weaken $f;
            } weaken => [qw($self)],
			  allowed => [qw($f)]
        );
        $self->send_frame($frame);
        $f
    } weaken => [qw($self)],
      allowed => [qw(%args)]);
}

=head2 delete

Deletes this queue.

=cut

sub delete {
    my $self = shift;
    my %args = @_;

    # Attempt to bind after we've successfully declared the exchange.
    $self->future->then(callback {
        my $self = shift;
        my $f = $self->loop->new_future;
        warn "Attempting to delete queue [" . $self->queue_name . "]" if DEBUG;

        my $frame = Net::AMQP::Frame::Method->new(
            channel => $self->channel->id,
            method_frame => Net::AMQP::Protocol::Queue::Delete->new(
                queue       => $self->queue_name,
                nowait      => 0,
            )
        );
        $self->push_pending(
            'Queue::DeleteOk' => callback {
                my $self = shift;
                $f->done($self) unless $f->is_ready;
				weaken $f;
            } weaken => [qw($self)],
			  allowed => [qw($f)]
        );
        $self->send_frame($frame);
        $f
    } weaken => [qw($self)],
      allowed => [qw(%args)]);
}

1;

__END__

=head1 SEE ALSO

=over 4

=item * L<Net::AMQP>

=item * L<AnyEvent::RabbitMQ>

=back

=head1 AUTHOR

Tom Molesworth <cpan@entitymodel.com>

=head1 LICENSE

Licensed under the same terms as Perl itself.
