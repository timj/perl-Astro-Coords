package Astro::Coords::Calibration;

=head1 NAME

Astro::Coords::Calibration - calibrations that do not have coordinates

=head1 SYNOPSIS

  $c = new Astro::Coords::Calibration();

=head1 DESCRIPTION

Occasionally observations do not have any associated coordinates.  In
particular calibration observations such as DARKs and ARRAY TESTS do
not require the telescope to be in any particular location. This class
exists in order that these types of observation can be processed in
similar ways to other observations (from a scheduling viewpoint
calibration observations always are an available target).

=cut

use 5.006;
use strict;
use warnings;

our $VERSION = '0.01';

use base qw/ Astro::Coords::Fixed /;


=head1 METHODS

This class inherits from C<Astro::Coords::Fixed>.

=head2 Constructor

=over 4

=item B<new>

Simply instantiates an object with an Azimuth of 0.0 degrees and an
elevation of 90 degrees. The exact values do not matter.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my $self = $class->SUPER::new( az => 0.0, el => 90.0 );
  return $self;
}

=back

=head2 General Methods

=over 4

=item B<type>

Return the coordinate type. In this case always return "CAL".

=cut

sub type {
  return "CAL";
}

=item B<array>

Returns a summary of the object in an 11 element array. All elements
are undefined except the first. This contains "CAL".

=cut

sub array {
  my $self = shift;
  return ($self->type,undef,undef,undef,undef,undef,undef,undef,undef,undef,undef);
}

=item B<stringify>

Returns stringified summary of the object. Always returns the
C<type()>.

=cut

sub stringify {
  my $self = shift;
  return $self->type;
}

=back

=head1 NOTES

Usually called via C<Astro::Coords>.

=head1 REQUIREMENTS

C<Astro::SLA> is used for all internal astrometric calculations.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

=head1 COPYRIGHT

Copyright (C) 2001 Particle Physics and Astronomy Research Council.
All Rights Reserved. This program is free software; you can
redistribute it and/or modify it under the same terms as Perl itself.

=cut

1;
