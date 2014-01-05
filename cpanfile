requires 'parent', 0;
requires 'curry', 0;
requires 'Future', '>= 0.15';
requires 'Try::Tiny', 0;
requires 'Mixin::Event::Dispatch', '>= 1.000';
requires 'Net::AMQP', '>= 0.04';
requires 'Class::ISA', 0;
requires 'List::UtilsBy', 0;
requires 'File::ShareDir', 0;
requires 'Closure::Explicit', 0;
requires 'IO::Async', '>= 0.50';

on 'test' => sub {
	requires 'Test::More', '>= 0.98';
	requires 'Test::Fatal', '>= 0.010';
	requires 'Test::Refcount', '>= 0.07';
};

