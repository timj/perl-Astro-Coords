package Astro::Coords::Planet;


=head1 NAME

Astro::Coords::Planet - coordinates relating to planetary motion

=head1 SYNOPSIS

  $c = new Astro::Coords::Planet( 'uranus' );

=head1 DESCRIPTION

This class is used by C<Astro::Coords> for handling coordinates
for planets..

=cut

use 5.006;
use strict;
use warnings;

our $VERSION = '0.02';

use Astro::SLA ();
use Astro::Coords::Angle;
use base qw/ Astro::Coords /;

use overload '""' => "stringify";

our @PLANETS = qw/ sun mercury venus moon mars jupiter saturn
  uranus neptune pluto /;

# invert the planet for lookup
my $i = 0;
our %PLANET = map { $_, $i++  } @PLANETS;

=head1 METHODS


=head2 Constructor

=over 4

=item B<new>

Instantiate a new object using the supplied options.

  $c = new Astro::Coords::Planet( 'mars' );

Returns undef on error.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my $planet = lc(shift);

  return undef unless defined $planet;

  # Check that we have a valid planet
  return undef unless exists $PLANET{$planet};

  bless { planet => $planet,
	  diameter => undef,
	}, $class;

}



=back

=head2 Accessor Methods

=over 4

=item B<planet>

Returns the name of the planet.

=cut

sub planet {
  my $self = shift;
  return $self->{planet};
}

=item B<name>

For planets, the name is always just the planet name.

=cut

sub name {
  my $self = shift;
  return $self->planet;
}

=back

=head1 General Methods

=over 4

=item B<array>

Return back 11 element array with first element containing the planet
name.

This method returns a standardised set of elements across all
types of coordinates.

=cut

sub array {
  my $self = shift;
  return ($self->planet, undef, undef,
	  undef, undef, undef, undef, undef, undef, undef, undef);
}

=item B<type>

Returns the generic type associated with the coordinate system.
For this class the answer is always "RADEC".

This is used to aid construction of summary tables when using
mixed coordinates.

It could be done using isa relationships.

=cut

sub type {
  return "PLANET";
}

=item B<stringify>

Stringify overload. Simple returns the name of the planet
in capitals.

=cut

sub stringify {
  my $self = shift;
  return uc($self->planet());
}

=item B<summary>

Return a one line summary of the coordinates.
In the future will accept arguments to control output.

  $summary = $c->summary();

=cut

sub summary {
  my $self = shift;
  my $name = $self->name;
  $name = '' unless defined $name;
  return sprintf("%-16s  %-12s  %-13s PLANET",$name,'','');
}

=item B<diam>

Returns the apparent angular planet diameter from the most recent calculation
of the apparent RA/Dec.

 $diam = $c->diam();

Returns the answer as a C<Astro::Coords::Angle> object. Note that this
number is not updated automatically. (so don't change the time and expect
to get the correct answer without first asking for a ra/dec calculation).

=cut

sub diam {
  my $self = shift;
  if (@_) {
    my $d = shift;
    $self->{diam} = new Astro::Coords::Angle( $d );
  }
  return $self->{diam};
}

=item B<_apparent>

Return the apparent RA and Dec (in radians) for the current
coordinates and time.

=cut

sub _apparent {
  my $self = shift;
  my $tel = $self->telescope;
  my $long = (defined $tel ? $tel->long : 0.0 );
  my $lat = (defined $tel ? $tel->lat : 0.0 );

  Astro::SLA::slaRdplan($self->_mjd_tt, $PLANET{$self->planet},
			$long, $lat, my $ra, my $dec, my $diam);

  # Store the diameter
  $self->diam( $diam );

  return($ra, $dec);
}

=item B<_default_horizon>

Returns the default horizon. For the sun returns Astro::Coords::SUN_RISE_SET.
For the Moon returns:

  -(  0.5666 deg + moon radius + moon's horizontal parallax )

       34 arcmin    15-17 arcmin    55-61 arcmin           =  4 - 12 arcmin

[see the USNO pages at: http://aa.usno.navy.mil/faq/docs/RST_defs.html]

For all other planets returns 0.

Note that the moon calculation requires that the date stored in the object
is close to the date for which the rise/set time is required.

The USNO web page is quite confusing on the definition for the moon since
in one place it implies that the moonrise occurs when the centre of the moon
is above the horizon by 5-10 arcminutes (the above calculation) but on the
moon data page comparing moonrise with tables for a specific day indicates a
moonrise of -48 arcminutes.

=cut

sub _default_horizon {
  my $self = shift;
  my $name = lc($self->name);

  if ($name eq 'sun') {
    return &Astro::Coords::SUN_RISE_SET;
  } elsif ($name eq 'moon') {
    return (-0.8 * Astro::SLA::DD2R);
    # See http://aa.usno.navy.mil/faq/docs/RST_defs.html
    my $refterm = 0.5666 * Astro::SLA::DD2R; # atmospheric refraction

    # Get the moon radius
    $self->_apparent();
    my $radius = $self->diam() / 2;

    # parallax - assume 57 arcminutes for now
    my $parallax = (57 * 60) * Astro::SLA::DAS2R;

    print "Refraction: $refterm  Radius: $radius  Parallax: $parallax\n";

    return ( -1 * ( $refterm + $radius - $parallax ) );
  } else {
    return 0;
  }
}

=back

=head1 NOTES

Usually called via C<Astro::Coords>.

=head1 REQUIREMENTS

C<Astro::SLA> is used for all internal astrometric calculations.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

=head1 COPYRIGHT

Copyright (C) 2001-2004 Particle Physics and Astronomy Research Council.
All Rights Reserved. This program is free software; you can
redistribute it and/or modify it under the same terms as Perl itself.

=cut

1;
