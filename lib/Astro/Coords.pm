package Astro::Coords;

=head1 NAME

Astro::Coords - Class for handling astronomical coordinates

=head1 SYNOPSIS

  use Astro::Coords;

  $c = new Astro::Coords( name => "My target",
                          ra   => '05:22:56',
                          dec  => '-26:20:40.4',
                          type => 'B1950'
                          units=> 'sexagesimal');

  $c = new Astro::Coords( long => '05:22:56',
                          lat  => '-26:20:40.4',
                          type => 'galactic');

  $c = new Astro::Coords( planet => 'mars' );

  $c = new Astro::Coords( elements => \%elements );

  $c = new Astro::Coords( az => 345, el => 45 );

  # Associate with an observer location
  $c->telescope( new Astro::Telescope( 'JCMT' ));

  # ...and a reference epoch for all calculations
  $date = Time::Piece->strptime($string, $format);
  $c->datetime( $date );

  # or use DateTime
  $date = DateTime->from_epoch( epoch => $epoch, time_zone => 'UTC' );
  $c->datetime( $date );

  # Return coordinates J2000, for the epoch stored in the datetime
  # object. This will work for all variants.
  ($ra, $dec) = $c->radec();
  $radians = $ra->radians;

  # or individually
  $ra = $c->ra();  # returns Astro::Coords::Angle::Hour object
  $dec = $c->dec( format => 'deg' );

  # Return coordinates J2000, epoch 2000.0
  $ra = $c->ra2000();
  $dec = $c->dec2000();

  # Return coordinats apparent, reference epoch, from location
  # In sexagesimal format.
  ($ra_app, $dec_app) = $c->apparent;
  $ra_app = $c->ra_app( format => 's');
  $dec_app = $c->dec_app( format => 's' );

  # Azimuth and elevation for reference epoch from observer location
  ($az, $el) = $c->azel;
  my $az = $c->az;
  my $el = $c->el;

  # obtain summary string of object
  $summary = "$c";

  # Obtain full summary as an array
  @summary = $c->array;

  # See if the target is observable for the current time
  # and telescope
  $obs = 1 if $c->isObservable;

  # Calculate distance to another coordinate (in radians)
  $distance = $c->distance( $c2 );

  # Calculate the rise and set time of the source
  $tr = $c->rise_time;
  $ts = $c->set_time;

  # transit elevation
  $trans = $c->transit_el;

  # transit time
  $mtime = $c->meridian_time();


=head1 DESCRIPTION

Class for manipulating and transforming astronomical coordinates.
Can handle the following coordinate types:

  + Equatorial RA/Dec, galactic (including proper motions and parallax)
  + Planets
  + Comets/Asteroids
  + Fixed locations in azimuth and elevations
  + interpolated apparent coordinates

For time dependent calculations a telescope location and reference
time must be provided. See C<Astro::Telescope> and C<DateTime> for
details on specifying location and reference epoch.

=cut

use 5.006;
use strict;
use warnings;
use warnings::register;
use Carp;
use vars qw/ $DEBUG /;
$DEBUG = 0;

our $VERSION = '0.08';

use Math::Trig qw/ acos /;
use Astro::SLA ();
use Astro::Coords::Angle;
use Astro::Coords::Angle::Hour;
use Astro::Coords::Equatorial;
use Astro::Coords::Elements;
use Astro::Coords::Planet;
use Astro::Coords::Interpolated;
use Astro::Coords::Fixed;
use Astro::Coords::Calibration;

use Scalar::Util qw/ blessed /;
use DateTime;
use Time::Piece;

# Constants for Sun rise/set and twilight definitions
# Elevation in radians
# See http://aa.usno.navy.mil/faq/docs/RST_defs.html
use constant SUN_RISE_SET => ( - (50 * 60) * Astro::SLA::DAS2R); # 50 arcmin
use constant CIVIL_TWILIGHT => ( - (6 * 3600) * Astro::SLA::DAS2R); # 6 deg
use constant NAUT_TWILIGHT => ( - (12 * 3600) * Astro::SLA::DAS2R); # 12 deg
use constant AST_TWILIGHT => ( - (18 * 3600) * Astro::SLA::DAS2R); # 18 deg

# This is a fudge. Not accurate
use constant MOON_RISE_SET => ( 5 * 60 * Astro::SLA::DAS2R);

=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

This can be treated as an object factory. The object returned
by this constructor depends on the arguments supplied to it.
Coordinates can be provided as orbital elements, a planet name
or an equatorial (or related) fixed coordinate specification (e.g.
right ascension and declination).

A complete (for some definition of complete) specification for
the coordinates in question must be provided to the constructor.
The coordinates given as arguments will be converted to an internal
format.

A planet name can be specified with:

  $c = new Astro::Coords( planet => "sun" );

Orbital elements as:

  $c = new Astro::Coords( elements => \%elements );

where C<%elements> must contain the names of the elements
as used in the SLALIB routine slaPlante.

Fixed astronomical oordinate frames can be specified using:

  $c = new Astro::Coords( ra => 
                          dec =>
			  long =>
			  lat =>
			  type =>
			  units =>
			);

C<ra> and C<dec> are used for HMSDeg systems (eg type=J2000). Long and
Lat are used for degdeg systems (eg where type=galactic). C<type> can
be "galactic", "j2000", "b1950", and "supergalactic".
The C<units> can be specified as "sexagesimal" (when using colon or
space-separated strings), "degrees" or "radians". The default is
determined from context.

Fixed (as in fixed on Earth) coordinate frames can be specified
using:

  $c = new Astro::Coords( dec =>
                          ha =>
                          tel =>
                          az =>
                          el =>
                          units =>
                        );

where C<az> and C<el> are the Azimuth and Elevation. Hour Angle
and Declination require a telescope. Units are as defined above.

Finally, if no arguments are given the object is assumed
to be of type C<Astro::Coords::Calibration>.

Returns C<undef> if an object could not be created.

=cut

sub new {
  my $class = shift;

  my %args = @_;

  my $obj;

  # Always try for a planet object first if $args{planet} is used
  # (it might be that ra/dec are being specified and planet is a target
  # name - this allows all the keys to be specified at once and the
  # object can decide the most likely coordinate object to use
  # This has the distinct disadvantage that planet is always tried
  # even though it is rare. We want to be able to throw anything
  # at this without knowing what we are.
  if (exists $args{planet} and defined $args{planet}) {
    $obj = new Astro::Coords::Planet( $args{planet} );
  }

  # planet did not work. Try something else.
  unless (defined $obj) {

    # For elements we must not only check for the elements key
    # but also make sure that that key points to a hash containing
    # at least the EPOCH or EPOCHPERIH key
    if (exists $args{elements} and defined $args{elements}
       && UNIVERSAL::isa($args{elements},"HASH") 
       &&  (exists $args{elements}{EPOCH}
       and defined $args{elements}{EPOCH})
       ||  (exists $args{elements}{EPOCHPERIH}
       and defined $args{elements}{EPOCHPERIH})
     ) {

      $obj = new Astro::Coords::Elements( %args );

    } elsif (exists $args{mjd1}) {

      $obj = new Astro::Coords::Interpolated( %args );

    } elsif (exists $args{type} and defined $args{type}) {

      $obj = new Astro::Coords::Equatorial( %args );

    } elsif (exists $args{az} or exists $args{el} or exists $args{ha}) {

      $obj = new Astro::Coords::Fixed( %args );

    } elsif ( scalar keys %args == 0 ) {

      $obj = new Astro::Coords::Calibration();

    } else {
    # unable to work out what you are asking for
      return undef;

    }
  }

  return $obj;
}


=back

=head2 Accessor Methods

=over 4

=item B<name>

Name of the target associated with the coordinates.

=cut

sub name {
  my $self = shift;
  if (@_) {
    $self->{name} = shift;
  }
  return $self->{name};
}

=item B<telescope>

Telescope object (an instance of Astro::Telescope) to use
for obtaining the position of the telescope to use for
the determination of source elevation.

  $c->telescope( new Astro::Telescope( 'JCMT' ));
  $tel = $c->telescope;

This method checks that the argument is of the correct type.

=cut

sub telescope {
  my $self = shift;
  if (@_) { 
    my $tel = shift;
    return undef unless UNIVERSAL::isa($tel, "Astro::Telescope");
    $self->{Telescope} = $tel;
  }
  return $self->{Telescope};
}


=item B<datetime>

Date/Time object to use when determining the source elevation.

  $c->datetime( new Time::Piece() );

Argument must be an object that has the C<mjd> method. Both
C<DateTime> and C<Time::Piece> objects are allowed.  A value of
C<undef> is supported. This will clear the time and force the current
time to be used on subsequent calls.

  $c->datetime( undef );

If no argument is specified, or C<usenow> is set to true, an object
referring to the current time (GMT/UT) is returned. This object may be
either a C<Time::Piece> object or a C<DateTime> object depending on
current implementation (but in modern versions it will be a
C<DateTime> object). If a new argument is supplied C<usenow> is always
set to false.

A copy of the input argument is created, guaranteeing a UTC representation.

=cut

sub datetime {
  my $self = shift;
  if (@_) {
    my $time = shift;

    # undef is okay
    croak "datetime: Argument does not have an mjd() method [class="
      . ( ref($time) ? ref($time) : $time) ."]"
      if (defined $time && !UNIVERSAL::can($time, "mjd"));
    $self->{DateTime} = _clone_time( $time );
    $self->usenow(0);
  }
  if (defined $self->{DateTime} && ! $self->usenow) {
    return $self->{DateTime};
  } else {
    return DateTime->now( time_zone => 'UTC' );
  }
}

=item B<has_datetime>

Returns true if a specific time is stored in the object, returns
false if no time is stored. (The value of C<usenow> is
ignored).

This is required because C<datetime> always returns a time.

=cut

sub has_datetime {
  my $self = shift;
  return (defined $self->{DateTime});
}

=item B<usenow>

Flag to indicate whether the current time should be used for calculations
regardless of whether an explicit time object is stored in C<datetime>.
This is useful when trying to determine the current position of a target
without affecting previous settings.

  $c->usenow( 1 );
  $usenow = $c->usenow;

Defaults to false.

=cut

sub usenow {
  my $self = shift;
  if (@_) {
    $self->{UseNow} = shift;
  }
  return $self->{UseNow};
}

=item B<comment>

A textual comment associated with the coordinate (optional).
Defaults to the empty string.

  $comment = $c->comment;
  $c->comment("An inaccurate coordinate");

Always returns an empty string if undefined.

=cut

sub comment {
  my $self = shift;
  if (@_) {
    $self->{Comment} = shift;
  }
  my $com = $self->{Comment};
  $com = '' unless defined $com;
  return $com;
}

=item B<native>

Returns the name of the method that should be called to return the
coordinates in a form as close as possible to those that were supplied
to the constructor. This method is useful if, say, the object is created
from Galactic coordinates but internally represented in a different
coordinate frame.

  $native_method = $c->native;

This method can then be called to retrieve the coordinates:

  ($c1, $c2) = $c->$native_method();

Currently, the native form will not exactly match the supplied form
if a non-standard equinox has been used, or if proper motions and parallax
are present, but the resulting answer can be used as a guide.

If no native method is obvious (e.g. for a planet), 'apparent' will
be returned.

=cut

sub native {
  my $self = shift;
  if (@_) {
    $self->{NativeMethod} = shift;
  }
  return (defined $self->{NativeMethod} ? $self->{NativeMethod} : 'apparent' );
}


=back

=head2 General Methods

=over 4

=item B<azel>

Return Azimuth and elevation for the currently stored time and telescope.
If no telescope is present the equator is used. Returns the Az and El
as C<Astro::Coords::Angle> objects.

 ($az, $el) = $c->azel();

=cut

sub azel {
  my $self = shift;
  my $ha = $self->ha;
  my $dec = $self->dec_app;
  my $tel = $self->telescope;
  my $lat = ( defined $tel ? $tel->lat : 0.0);
  Astro::SLA::slaDe2h( $ha, $dec, $lat, my $az, my $el );
  $az = new Astro::Coords::Angle( $az, units => 'rad', range => '2PI' );
  $el = new Astro::Coords::Angle( $el, units => 'rad' );
  return ($az, $el);
}


=item B<ra_app>

Apparent RA for the current time.

  $ra_app = $c->ra_app( format => "s" );

See L<"NOTES"> for details on the supported format specifiers
and default calling convention.

=cut

sub ra_app {
  my $self = shift;
  my %opt = @_;

  my $ra = ($self->apparent)[0];
  return $ra->in_format( $opt{format} );
}


=item B<dec_app>

Apparent Dec for the currently stored time.

  $dec_app = $c->dec_app( format => "s" );

See L<"NOTES"> for details on the supported format specifiers
and default calling convention.


=cut

sub dec_app {
  my $self = shift;
  my %opt = @_;
  my $dec = ($self->apparent)[1];
  return $dec->in_format( $opt{format} );
}

=item B<ha>

Get the hour angle for the currently stored LST. By default HA is returned
as an C<Astro::Coords::Angle::Hour> object.

  $ha = $c->ha;
  $ha = $c->ha( format => "h" );

By default the Hour Angle will be normalised to +/- 12h if an explicit
format is specified.

See L<"NOTES"> for details on the supported format specifiers
and default calling convention.

=cut

# normalize key was supported but should its absence imply no normalization?

sub ha {
  my $self = shift;
  my %opt = @_;
  my $ha = $self->_lst - $self->ra_app;

  # Always normalize?
  $ha = new Astro::Coords::Angle::Hour( $ha, units => 'rad', range => 'PI' );
  return $ha->in_format( $opt{format} );
}

=item B<az>

Azimuth of the source for the currently stored time at the current
telescope. See L<"NOTES"> for details on the supported format specifiers
and default calling convention.

  $az = $c->az();

If no telescope is defined the equator is used.

=cut

sub az {
  my $self = shift;
  my %opt = @_;
  my ($az, $el) = $self->azel();
  return $az->in_format( $opt{format} );
}

=item B<el>

Elevation of the source for the currently stored time at the current
telescope. See L<"NOTES"> for details on the supported format specifiers
and default calling convention.

  $el = $c->el();

If no telescope is defined the equator is used.

=cut

sub el {
  my $self = shift;
  my %opt = @_;
  my ($az, $el) = $self->azel();
  return $el->in_format( $opt{format} );
}

=item B<airmass>

Airmass of the source for the currently stored time at the current
telescope.

  $am = $c->airmass();

Value determined from the current elevation.

=cut

sub airmass {
  my $self = shift;
  my $el = $self->el;
  my $zd = Astro::SLA::DPIBY2 - $el;
  return Astro::SLA::slaAirmas( $zd );
}

=item B<radec>

Return the J2000 Right Ascension and Declination for the target. Unless
overridden by a subclass, this converts from the apparent RA/Dec to J2000.
Returns two C<Astro::Coords::Angle> objects.

 ($ra, $dec) = $c->radec();

=cut

sub radec {
  my $self = shift;
  my ($ra_app, $dec_app) = $self->apparent;
  my $mjd = $self->_mjd_tt;
  Astro::SLA::slaAmp($ra_app, $dec_app, $mjd, 2000.0, my $rm, my $dm);
  return (new Astro::Coords::Angle::Hour( $rm, units => 'rad', range => '2PI'),
	  new Astro::Coords::Angle( $dm, units => 'rad' ));
}

=item B<ra>

Return the J2000 Right ascension for the target. Unless overridden
by a subclass this converts the apparent RA/Dec to J2000.

  $ra2000 = $c->ra( format => "s" );

Calls the C<radec> method. See L<"NOTES"> for details on the supported
format specifiers and default calling convention.

=cut

sub ra {
  my $self = shift;
  my %opt = @_;
  my ($ra,$dec) = $self->radec;
  return $ra->in_format( $opt{format} );
}

=item B<dec>

Return the J2000 declination for the target. Unless overridden
by a subclass this converts the apparrent RA/Dec to J2000.

  $dec2000 = $c->dec( format => "s" );

Calls the C<radec> method. See L<"NOTES"> for details on the supported
format specifiers and default calling convention.

=cut

sub dec {
  my $self = shift;
  my %opt = @_;
  my ($ra,$dec) = $self->radec;
  return $dec->in_format( $opt{format} );
}

=item B<glong>

Return Galactic longitude. See L<"NOTES"> for details on the supported
format specifiers and default calling convention.

  $glong = $c->glong( format => "s" );

=cut

sub glong {
  my $self = shift;
  my %opt = @_;
  my ($glong,$glat) = $self->glonglat();
  return $glong->in_format( $opt{format} );
}

=item B<glat>

Return Galactic latitude. See L<"NOTES"> for details on the supported
format specifiers and default calling convention.


  $glat = $c->glat( format => "s" );

=cut

sub glat {
  my $self = shift;
  my %opt = @_;
  my ($glong,$glat) = $self->glonglat();
  return $glat->in_format( $opt{format} );
}

=item B<sglong>

Return SuperGalactic longitude. See L<"NOTES"> for details on the
supported format specifiers and default calling convention.

  $sglong = $c->sglong( format => "s" );

=cut

sub sglong {
  my $self = shift;
  my %opt = @_;
  my ($sglong,$sglat) = $self->sglonglat();
  return $sglong->in_format( $opt{format} );
}

=item B<sglat>

Return SuperGalactic latitude. See L<"NOTES"> for details on the supported format specifiers and default calling convention.

  $glat = $c->sglat( format => "s" );

=cut

sub sglat {
  my $self = shift;
  my %opt = @_;
  my ($sglong,$sglat) = $self->sglonglat();
  return $sglat->in_format( $opt{format} );
}

=item B<ecllong>

Return Ecliptic longitude. See L<"NOTES"> for details on the supported
format specifiers and default calling convention.

  $eclong = $c->ecllong( format => "s" );

=cut

sub ecllong {
  my $self = shift;
  my %opt = @_;
  my ($eclong,$eclat) = $self->ecllonglat();
  return $eclong->in_format( $opt{format} );
}

=item B<ecllat>

Return ecliptic latitude. See L<"NOTES"> for details on the supported
format specifiers and default calling convention.

  $eclat = $c->ecllat( format => "s" );

=cut

sub ecllat {
  my $self = shift;
  my %opt = @_;
  my ($eclong,$eclat) = $self->ecllonglat();
  return $eclat->in_format( $opt{format} );
}

=item B<glonglat>

Calculate Galactic longitude and latitude. Position is calculated for
the current ra/dec position (as returned by the C<radec> method).

 ($long, $lat) = $c->glonglat;

Answer is returned as two C<Astro::Coords::Angle> objects.

=cut

sub glonglat {
  my $self = shift;
  my ($ra,$dec) = $self->radec;
  Astro::SLA::slaEqgal( $ra, $dec, my $long, my $lat );
  return (new Astro::Coords::Angle($long, units => 'rad', range => '2PI'),
	  new Astro::Coords::Angle($lat, units => 'rad'));
}

=item B<sglonglat>

Calculate Super Galactic longitude and latitude.

 ($slong, $slat) = $c->sglonglat;

Answer is returned as two C<Astro::Coords::Angle> objects.

=cut

sub sglonglat {
  my $self = shift;
  my ($glong, $glat) = $self->glonglat();
  Astro::SLA::slaGalsup( $glong, $glat, my $sglong, my $sglat);
  return (new Astro::Coords::Angle($sglong, units => 'rad', range => '2PI'),
	  new Astro::Coords::Angle($sglat, units => 'rad'));
}

=item B<ecllonglat>

Calculate the ecliptic longitude and latitude for the epoch stored in
the object. Position is calculated for the current ra/dec position (as
returned by the C<radec> method.

 ($long, $lat) = $c->ecllonglat();

Answer is returned as two C<Astro::Coords::Angle> objects.

=cut

sub ecllonglat {
  my $self = shift;
  my ($ra, $dec) = $self->radec;
  Astro::SLA::slaEqecl( $ra, $dec, $self->_mjd_tt, my $long, my $lat );
  return (new Astro::Coords::Angle($long, units => 'rad', range => '2PI'),
	  new Astro::Coords::Angle($lat, units => 'rad'));
}

=item B<radec1950>

Return the FK4 B1950 coordinates. In the base class these are
calculated by precessing the J2000 RA/Dec for the current date and
time, which are themselves derived from the apparent RA/Dec for the
current time.

 ($ra, $dec) = $c->radec1950;

Results are returned as two C<Astro::Coords::Angle> objects.

=cut

sub radec1950 {
  my $self = shift;
  my ($ra, $dec) = $self->radec;

  Astro::SLA::slaFk54z($ra,$dec,1950.0,my $r1950, my $d1950, my $dr1950, my $dd1950);

  return (new Astro::Coords::Angle::Hour( $r1950, units => 'rad', range => '2PI'),
	  new Astro::Coords::Angle( $d1950, units => 'rad' ));
}

=item B<pa>

Parallactic angle of the source for the currently stored time at the
current telescope. See L<"NOTES"> for details on the supported format
specifiers and default calling convention.

  $pa = $c->pa();
  $padeg = $c->pa( format => 'deg' );

If no telescope is defined the equator is used.

=cut

sub pa {
  my $self = shift;
  my %opt = @_;
  my $ha = $self->ha;
  my $dec = $self->dec_app;
  my $tel = $self->telescope;
  my $lat = ( defined $tel ? $tel->lat : 0.0);
  my $pa = Astro::SLA::slaPa($ha, $dec, $lat);
  $pa = new Astro::Coords::Angle( $pa, units => 'rad' );
  return $pa->in_format( $opt{format} );
}


=item B<isObservable>

Determine whether the coordinates are accessible for the current
time and telescope.

  $isobs = $c->isObservable;

Returns false if a telescope has not been specified (see
the C<telescope> method) or if the specified telescope does not
know its own limits.

=cut

sub isObservable {
  my $self = shift;

  # Get the telescope
  my $tel = $self->telescope;
  return 0 unless defined $tel;

  # Get the limits hash
  my %limits = $tel->limits;

  if (exists $limits{type}) {

    if ($limits{type} eq 'AZEL') {

      # Get the current elevation of the source
      my $el = $self->el;

      if ($el > $limits{el}{min} and $el < $limits{el}{max}) {
	return 1;
      } else {
	return 0;
      }

    } elsif ($limits{type} eq 'HADEC') {

      # Get the current HA
      my $ha = $self->ha( normalize => 1 );

      if ( $ha > $limits{ha}{min} and $ha < $limits{ha}{max}) {
	my $dec= $self->dec_app;

	if ($dec > $limits{dec}{min} and $dec < $limits{dec}{max}) {
	  return 1;
	} else {
	  return 0;
	}

      } else {
	return 0;
      }

    } else {
      # have no idea
      return 0;
    }

  } else {
    return 0;
  }

}


=item B<array>

Return a summary of this object in the form of an array containing
the following:

  coordinate type (eg PLANET, RADEC, MARS)
  ra2000          (J2000 RA in radians [for equatorial])
  dec2000         (J2000 dec in radians [for equatorial])
  elements        (up to 8 orbital elements)

=cut

sub array {
  my $self = shift;
  croak "The method array() must be subclassed\n";
}

=item B<distance>

Calculate the distance (on the tangent plane) between the current
coordinate and a supplied coordinate.

  $dist = $c->distance( $c2 );
  @dist = $c->distance( $c2 );

In scalar context the distance is returned as an
C<Astro::Coords::Angle> object In list context returns the individual
"x" and "y" offsets (as C<Astro::Coords::Angle> objects).

Returns undef if there was an error during the calculation (e.g. because
the new coordinate was too far away).

=cut

sub distance {
  my $self = shift;
  my $offset = shift;

  Astro::SLA::slaDs2tp($offset->ra_app, $offset->dec_app,
		       $self->ra_app, $self->dec_app,
		       my $xi, my $eta, my $j);

  return () unless $j == 0;

  if (wantarray) {
    return (new Astro::Coords::Angle($xi, units => 'rad'),
	    new Astro::Coords::Angle($eta, units => 'rad'));
  } else {
    my $dist = ($xi**2 + $eta**2)**0.5;
    return new Astro::Coords::Angle( $dist, units => 'rad' );
  }
}


=item B<status>

Return a status string describing the current coordinates.
This consists of the current elevation, azimuth, hour angle
and declination. If a telescope is defined the observability
of the target is included.

  $status = $c->status;

=cut

sub status {
  my $self = shift;
  my $string;

  $string .= "Target name:    " . $self->name . "\n"
    if $self->name;

  $string .= "Coordinate type:" . $self->type ."\n";

  if ($self->type ne 'CAL') {

    my ($az,$el) = $self->azel;
    $string .= "Elevation:      " . $el->degrees ." deg\n";
    $string .= "Azimuth  :      " . $az->degrees ." deg\n";
    my $ha = $self->ha->hours;
    $string .= "Hour angle:     " . $ha ." hrs\n";
    my ($ra_app, $dec_app) = $self->apparent;
    $string .= "Apparent RA :   " . $ra_app->string . "\n";
    $string .= "Apparent dec:   " . $dec_app->string ."\n";

    # Transit time
    $string .= "Time of next transit:" . $self->meridian_time->datetime ."\n";
    $string .= "Transit El:     " . $self->transit_el(format=>'d')." deg\n";
    my $ha_set = $self->ha_set( format => 'hour');
    $string .= "Hour Ang. (set):" . (defined $ha_set ? $ha_set : '??')." hrs\n";

    my $t = $self->rise_time;
    $string .= "Next Rise time:      " . $t->datetime . "\n" if defined $t;
    $t = $self->set_time;
    $string .= "Next Set time:       " . $t->datetime . "\n" if defined $t;

    # This check was here before we added a RA/Dec to the
    # base class.
    if ($self->can('radec')) {
      my ($ra, $dec) = $self->radec;
      $string .= "RA (J2000):     " . $ra->string . "\n";
      $string .= "Dec(J2000):     " . $dec->string . "\n";
    }
  }

  if (defined $self->telescope) {
    my $name = (defined $self->telescope->fullname ?
		$self->telescope->fullname : $self->telescope->name );
    $string .= "Telescope:      $name\n";
    if ($self->isObservable) {
      $string .= "The target is currently observable\n";
    } else {
      $string .= "The target is not currently observable\n";
    }
  }

  $string .= "For time ". $self->datetime->datetime ."\n";
  my $fmt = 's';
  $string .= "LST: ". $self->_lst->hours ."\n";

  return $string;
}

=item B<calculate>

Calculate target positions for a range of times.

  @data = $c->calculate( start => $start,
			 end => $end,
			 inc => $increment,
		         units => 'deg'
		       );

The start and end times are either C<Time::Piece> or C<DateTime>
objects and the increment is either a C<Time::Seconds> object, a
C<DateTime::Duration> object (in fact, an object that implements the
C<seconds> method) or an integer. If the end time will not necessarily
be used explictly if the increment does not divide into the total time
gap exactly. None of the returned times will exceed the end time. The
increment must be greater than zero but the start and end times can be
identical.

Returns an array of hashes. Each hash contains 

  time [same object class as provided as argument]
  elevation
  azimuth
  parang
  lst [always in radians]

The angles are in the units specified (radians, degrees or sexagesimal). They
will be Angle objects if no units are specified.

Note that this method returns C<DateTime> objects if it was given C<DateTime>
objects, else it returns C<Time::Piece> objects.

=cut

sub calculate {
  my $self = shift;

  my %opt = @_;

  croak "No start time specified" unless exists $opt{start};
  croak "No end time specified" unless exists $opt{end};
  croak "No time increment specified" unless exists $opt{inc};

  # Get the increment as an integer (DateTime::Duration or Time::Seconds)
  my $inc = $opt{inc};
  if (UNIVERSAL::can($inc, "seconds")) {
    $inc = $inc->seconds;
  }
  croak "Increment must be greater than zero" unless $inc > 0;

  # Determine date class to use for calculations
  my $dateclass = blessed( $opt{start} );
  croak "Start time must be either Time::Piece or DateTime object"
    if (!$dateclass || 
	($dateclass ne "Time::Piece" && $dateclass ne 'DateTime' ));

  my @data;

  # Get a private copy of the date object for calculations
  # (copy constructor)
  my $current = _clone_time( $opt{start} );

  while ( $current->epoch <= $opt{end}->epoch ) {

    # Hash for storing the data
    my %timestep;

    # store a copy of the time
    $timestep{time} = _clone_time( $current );

    # Set the time in the object
    # [standard problem with knowing whether we are overriding
    # another setting]
    $self->datetime( $current );

    # Now calculate the positions
    $timestep{elevation} = $self->el( format => $opt{units} );
    $timestep{azimuth} = $self->az( format => $opt{units} );
    $timestep{parang} = $self->pa( format => $opt{units} );
    $timestep{lst}    = $self->_lst();

    # store the timestep
    push(@data, \%timestep);

    # increment the time
    $current += $inc;

  }

  return @data;

}

=item B<rise_time>

Next time the target will appear above the horizon (starting from the
time stored in C<datetime>). By default returns undef if the target is
already up (as determined by looking at the current date value),
specifying the "nearest" option to the hash will allow rise times that
have already occurred. An optional argument can be given (as a hash
with key "horizon") specifying a different elevation to the horizon
(in radians).

  $t = $c->rise_time();
  $t = $c->rise_time( horizon => $el );

  $t = $c->rise_time( nearest => (1 * Astro::SLA::DD2R) );

An iterative algorithm is used to ensure that the time returned
by this routine does correspond to the elevation requested for the horizon.
This is required for non-sidereal objects, especially the Sun and Moon.

Returns a C<Time::Piece> object or a C<DateTime> object depending on the
type of object that is returned by the C<datetime> method.

BUG: Does not distinguish a source that never rises from a source
that never sets.

=cut

sub rise_time {
  my $self = shift;
  my %opt = @_;

  # Calculate the HA required for setting
  my $ha_set = $self->ha_set( %opt, format => 'radians' );
  return if ! defined $ha_set;

  # and convert to seconds
  $ha_set *= Astro::SLA::DR2S;

  # Calculate the transit time
  my $mt = $self->meridian_time( nearest => $opt{nearest} );

  my $use_dt;
  if ($self->_isdt($mt) ) {
    $ha_set = new DateTime::Duration( seconds => $ha_set );
  }

  # Calculate rise time by subtracting the hour angle
  # This is an estimate for non sidereal sources
  # For non-sidereal sources we need to use this as a starting
  # point for iteration
  my $rise = $mt - $ha_set;

  # Get the current time (do not modify it since we need to put it back)
  my $reftime = $self->datetime;

  # Determine whether we have to remember the cache
  my $havetime = $self->has_datetime;

  # Store the rise time
  $self->datetime( $rise );

  # Requested elevation
  my $refel = (defined $opt{horizon} ? $opt{horizon} :
		 $self->_default_horizon );

  # Verify convergence
  $self->_iterative_el( $refel, 1 );
  $rise = $self->datetime;

  # Reset the clock
  if ($havetime) {
    $self->datetime( $reftime );
  } else {
    $self->datetime( undef );
  }

  # If the rise time has already happened return undef
  # unless we are allowing earlier times
  if (!$opt{nearest}) {
    # return the time only if we are in the future
    return $rise if (_cmp_time($rise, $self->datetime) >= 0);
  } else {
    return $rise;
  }
  return;
}

=item B<set_time>

Time at which the target will set below the horizon.  (starting from
the time stored in C<datetime>). Returns C<undef> if the target is
never visible. An optional argument can be given specifying a
different elevation to the horizon (in radians). Since
C<meridian_time> is guaranteed to be in the future, this method should
always return the next set time since that always follows a transit.

  $t = $c->set_time();
  $t = $c->set_time( horizon => $el );

Returns a C<Time::Piece> object or a C<DateTime> object depending on the
type of object that is returned by the C<datetime> method.

Note that whilst the set time returned by this method will always be
in the future the calculation can be performed twice. This is because
the set time is first calculated relative to the nearest meridian time
(which may be in the past) and, if that set time is in the past, it is
recalculated for the next transit (which is guaranteed to result in a
set time in the future).


BUG: Does not distinguish a source that never rises from a source
that never sets.

=cut

sub set_time {
  my $self = shift;
  my %opt = @_;

  # Calculate the HA required for setting
  my $ha_set = $self->ha_set( %opt, format=> 'radians' );
  return if ! defined $ha_set;

  # and convert to seconds
  $ha_set *= Astro::SLA::DR2S;

  # and thence to a duration if required
  if ($self->_isdt()) {
    $ha_set = new DateTime::Duration( seconds => $ha_set );
  }

  # Get the current time (do not modify it since we need to put it back)
  my $reftime = $self->datetime;

  # Determine whether we have to remember the cache
  my $havetime = $self->has_datetime;

  # Need the requested horizon
  my $refel = (defined $opt{horizon} ? $opt{horizon} :
		 $self->_default_horizon );

  my $set;
  # Calculate first for nearest meridian and then for
  # next meridian. We want the set time to be in our future.
  # $n indicates whether we are requesting the nearest meridian
  # time or simply the one in the future.
  for my $n (1, 0) {
    # Calculate the transit time
    my $mt = $self->meridian_time( nearest => $n );

    $set = $mt + $ha_set;

    # Now verify the calculated set time corresponds to the requested
    # elevation using an iterative approach.
    # Do not bother if the estimated time is more than an hour in the past
    # since the approximation should be more accurate than that
    if ( $reftime->epoch - $set->epoch < 3600 ) {
      $self->datetime( $set );
      $self->_iterative_el( $refel, -1 );
      $set = $self->datetime;

      # and restore the reference date
      # Reset the clock
      if ($havetime) {
	$self->datetime( $reftime );
      } else {
	$self->datetime( undef );
      }
    }

    # If the set time is in the future we jump out of the loop
    # since everything is okay
    last if (_cmp_time( $set, $self->datetime ) >= 0 );

  }

  # Should not happen, but check that we if have something set
  # it is in the future
  $set = undef if (_cmp_time( $set, $self->datetime) < 0);

  return $set;
}


=item B<ha_set>

Hour angle at which the target will set. Negate this value to obtain
the rise time. By default assumes the target sets at an elevation of 0
degrees. An optional hash can be given with key of "horizon"
specifying a different elevation (in radians).

  $ha = $c->ha_set;
  $ha = $c->ha_set( horizon => $el );

Returned by default as an C<Astro::Coords::Angle::Hour> object unless
an explicit "format" is specified.

  $ha = $c->ha_set( horizon => $el, format => 'h');

There are predefined elevations for events such as 
Sun rise/set and Twilight (only relevant if your object
refers to the Sun). See L<"CONSTANTS"> for more information.

Returns C<undef> if the target never reaches the specified horizon.
(maybe it is circumpolar).

For the Sun and moon this calculation will not be very accurate since
it depends on the time for which the calculation is to be performed
(the time is not used by this routine) and the rise Hour Angle and
setting Hour Angle will differ (especially for the moon) . These
effects are corrected for by the C<rise_time> and C<set_time>
methods.

In some cases for the Moon, an iterative technique is used to calculate
the hour angle when the Moon is near transit (the simple geometrical
arguments do not correctly calculate the transit elevation).

=cut

sub ha_set {
  my $self = shift;

  # Get the reference horizon elevation
  my %opt = @_;

  my $horizon = (defined $opt{horizon} ? $opt{horizon} :
		 $self->_default_horizon );

  # Get the telescope position
  my $tel = $self->telescope;

  # Get the longitude (in radians)
  my $lat = (defined $tel ? $tel->lat : 0.0 );

  # Declination
  my $dec = $self->dec_app;

  # Calculate the hour angle for this elevation
  # See http://www.faqs.org/faqs/astronomy/faq/part3/section-5.html
  my $cos_ha0 = ( sin($horizon) - sin($lat)*sin( $dec ) ) /
    ( cos($lat) * cos($dec) );

  # Make sure we have a valid number for the cosine
  if (lc($self->name) eq 'moon' && abs($cos_ha0) > 1) {
    # for the moon this routine can incorrectly determine
    # cos HA near transit [in fact it always will be inaccurate
    # but near transit it won't return any value at all]
    # Calculate tranist elevation and if it is grater than the
    # requested "horizon" use an iterative technique to find the
    # set time.
    if ($self->transit_el > $horizon) {
      my $reftime = $self->datetime;
      my $havedt = $self->has_datetime;
      my $mt = $self->meridian_time();
      $self->datetime( $mt );
      $self->_iterative_el( $horizon, -1 );
      my $seconds = $self->datetime->epoch - $mt->epoch;
      $cos_ha0 = cos( $seconds * Astro::SLA::DS2R );
      $self->datetime( ($havedt ? $reftime : undef ) );
    }
  }

  return undef if abs($cos_ha0) > 1;

  # Work out the hour angle for this elevation
  my $ha0 = acos( $cos_ha0 );

  # If we are the Sun we need to convert this to solar time
  # time from sidereal time
  $ha0 *= 365.2422/366.2422
    unless (lc($self->name) eq 'sun' && $self->isa("Astro::Coords::Planet"));


#  print "HA 0 is $ha0\n";
#  print "#### in hours: ". ( $ha0 * Astro::SLA::DR2S / 3600)."\n";

  # return the result (converting if necessary)
  return Astro::Coords::Angle::Hour->new( $ha0, units => 'rad',
					  range => 'PI')->in_format($opt{format});

}

=item B<meridian_time>

Calculate the meridian time for this target (the time at which
the source transits).

  MT(UT) = apparent RA - LST(UT=0)

By default the next transit following the current time is calculated and
returned as a C<Time::Piece> or C<DateTime> object (depending on what
is stored in C<datetime>).

If you are happy to have a transit that has just occured (especially
useful if you are simply trying to calculate values for a particularly
day or have just passed transit and need to calculate a set time), use
the "nearest" option set to true

  $mt = $c->meridian_time( nearest => 1 );

=cut

sub meridian_time {
  my $self = shift;
  my %opt = @_;

  # Get the current time (do not modify it since we need to put it back)
  my $reftime = $self->datetime;

  # Determine whether we have to remember the cache
  my $havetime = $self->has_datetime;

  my $dtime; # do we have DateTime objects

  # Check Time::Piece first since there is a possibility that 
  # this is really a subclass of DateTime
  if ($reftime->isa( "Time::Piece")) {
    $dtime = 0;
  } elsif ($reftime->isa("DateTime")) {
    $dtime = 1;
  } else {
    croak "Unknown DateTime object class";
  }

  # For fast moving objects such as planets, we need to calculate
  # the transit time iteratively since the apparent RA/Dec will change
  # slightly during the night so we need to adjust the internal clock
  # to get it close to the actual transit time. We also need to make sure
  # that we are starting at the correct reference time so start at the
  # current time and look forward until we get a transit time > than
  # our start time

  # Somewhere to store the previous time so we can make sure things
  # are iterating nicely
  my $prevtime;

  # The current best guess of the meridian time
  my $mtime;

  # Number of times we want to loop before aborting
  my $max = 10;

  # Tolerance for good convergence
  my $tol = 1;

  # Increment (in hours) to jump forward each loop
  # Need to make sure we lock onto the correct transit so I'm
  # wary of jumping forward by exactly 24 hours
  my $inc = 12;
  $inc = 6 if lc($self->name) eq 'moon';

  # Loop until mtime is greater than the reftime
  # and (mtime - prevtime) is smaller than a second
  # and we have not looped more than $max times
  # There is probably an analytical solution. The problem is that
  # the apparent RA depends on the current time yet the apparent RA
  # varies with time
  my $count = 0;
  print "Looping..............".$reftime->datetime."\n" if $DEBUG;
  while ( $count <= $max ) {
    $count++;

    if (defined $mtime) {
      $prevtime = _clone_time( $mtime );
      $self->datetime( $mtime );
    }
    $mtime = $self->_local_mtcalc();
    print "New meridian time: ".$mtime->datetime ."\n" if $DEBUG;

    # if we want to make sure we have the next transit, we need
    # to compare the calculated time with the reference time
    if (!$opt{nearest}) {

      # Calculate the difference in epoch seconds before the current
      # object reference time and the calculate transit time.
      # Use ->epoch rather than overload since I'm having problems
      # with Duration objects
      my $diff = $reftime->epoch - $mtime->epoch;
      if ($diff > 0) {
	print "Need to offset....\n" if $DEBUG;
	# this is an earlier transit time
	# Need to keep jumping forward until we lock on to a meridian
	# time that ismore recent than the ref time
	if ($dtime) {
	  $mtime->add( hours => ($count * $inc));
	} else {
	  $mtime = $mtime + ($count * $inc * Time::Seconds::ONE_HOUR);
	}
      }
    }

    # End loop if the difference between meridian time and calculated
    # previous time is less than the acceptable tolerance
    if (defined $prevtime && defined $mtime) {
      last if (abs($mtime->epoch - $prevtime->epoch) <= $tol);
    }
  }

  # warn if we did not converge
  carp "Meridian time calculation failed to converge"
     if $count > $max;

  # Reset the clock
  if ($havetime) {
    $self->datetime( $reftime );
  } else {
    $self->datetime( undef );
  }

  # return the time
  return $mtime;
}

# Returns true if 
#    time - reftime is negative

# Returns RA-LST added on to reference time
sub _local_mtcalc {
  my $self = shift;

  # Now calculate the offset from the RA of the source.
  # Note that RA should be apparent RA and so the time should
  # match the actual time stored in the object.
  # Make sure the LST and Apparent RA are -PI to +PI
  # so that we do not jump whole days
  my $lst = Astro::SLA::slaDrange($self->_lst);
  my $ra_app = Astro::SLA::slaDrange( $self->ra_app );
  my $offset = $ra_app - $lst;

  # This is in radians. Need to convert it to seconds
  my $offset_sec = $offset * Astro::SLA::DR2S;

#  print "LST:            $lst\n";
#  print "RA App:         ". $self->ra_app ."\n";
#  print "Offset radians: $offset\n";
#  print "Offset seconds: $offset_sec\n";

  # If we are not the Sun we need to convert this to sidereal
  # time from solar time
  $offset_sec *= 365.2422/366.2422
    unless (lc($self->name) eq 'sun' && $self->isa("Astro::Coords::Planet"));

  my $datetime = $self->datetime;
  if ($datetime->isa('Time::Piece')) {
    return ($datetime + $offset_sec);
  } else {
    return $datetime->clone->add( seconds => $offset_sec );
  }

#  return $mtime;
}

=item B<transit_el>

Elevation at transit. This is just the elevation at Hour Angle = 0.0.
(ie at C<meridian_time>).

Format is supported as for the C<el> method. See L<"NOTES"> for
details on the supported format specifiers and default calling
convention.

  $el = $c->transit_el( format => 'deg' );

=cut

sub transit_el {
  my $self = shift;

  # Get meridian time
  my $mtime = $self->meridian_time();

  # Cache the current time if required
  # Note that we can leave $cache as undef if there is no
  # real time.
  my $cache;
  $cache = $self->datetime if $self->has_datetime;

  # set the new time
  $self->datetime( $mtime );

  # calculate the elevation
  my $el = $self->el( @_ );

  # fix the time back to what it was (including an undef value
  # if we did not read the cache).
  $self->datetime( $cache );

  return $el;
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

The following methods are not part of the public interface and can be
modified or removed for any release of this module.

=over 4

=item B<_lst>

Calculate the LST for the current date/time and
telescope and return it (in radians).

If no date/time is specified the current time will be used.
If no telescope is defined the LST will be from Greenwich.

This is labelled as an internal routine since it is not clear whether
the method to determine LST should be here or simply placed into
C<DateTime>. In practice this simply calls the
C<Astro::SLA::ut2lst> function with the correct args (and therefore
does not need the MJD). It will need the longitude though so we
calculate it here.

=cut

sub _lst {
  my $self = shift;
  my $time = $self->datetime;
  my $tel = $self->telescope;

  # Get the longitude (in radians)
  my $long = (defined $tel ? $tel->long : 0.0 );

  # Return the first arg
  # Note that we guarantee a UT time representation
  my $lst = (Astro::SLA::ut2lst( $time->year, $time->mon,
				 $time->mday, $time->hour,
				 $time->min, $time->sec, $long))[0];
  return new Astro::Coords::Angle::Hour( $lst, units => 'rad', range => '2PI');
}

=item B<_mjd_tt>

Internal routine to retrieve the MJD in TT (Terrestrial time) rather than UTC time.

=cut

sub _mjd_tt {
  my $self = shift;
  my $mjd = $self->datetime->mjd;
  my $offset = Astro::SLA::slaDtt( $mjd );
  $mjd += ($offset / (86_400));
  return $mjd;
}

=item B<_clone_time>

Internal routine to copy a Time::Piece or DateTime object
into a new object for internal storage.

  $clone = _clone_time( $orig );

=cut

sub _clone_time {
  my $input = shift;
  return unless defined $input;

  if (UNIVERSAL::isa($input, "Time::Piece")) {
    return Time::Piece::gmtime( $input->epoch );
  } elsif (UNIVERSAL::isa($input, "DateTime")) {
    return DateTime->from_epoch( epoch => $input->epoch, 
			         time_zone => 'UTC' );
  }
  return;
}

=item B<_cmp_time>

Internal routine to Compare two times (assuming the same class)

  $cmp = _cmp_time( $a, $b );

Returns 1 if $a > $b (epoch)
       -1 if $a < $b (epoch)
        0 if $a == $b (epoch)

Currently assumes epoch is enough for comparison and so works
for both DateTime and Time::Piece objects.

=cut

sub _cmp_time {
  my $t1 = shift;
  my $t2 = shift;
  my $e1 = $t1->epoch;
  my $e2 = $t2->epoch;
  return $e1 <=> $e2;
}

=item B<_default_horizon>

Returns the default horizon to use for rise/set calculations.
Normally, a value is supplied to the relevant routines.

In the base class, returns 0. Can be overridden by subclasses (in particular
the moon and sun).

=cut

sub _default_horizon {
  return 0;
}

=item B<_iterative_el>

Use an iterative technique to calculate the time the object passes through
a specified elevation. This routine is used for non-sidereal objects (especially
the moon and fast asteroids) where a simple calculation assuming a sidereal
object may lead to inaccuracies of a few minutes (maybe even 10s of minutes).
It is called by both C<set_time> and C<rise_time> to converge on an accurate
time of elevation.

  $self->_iterative_el( $refel, $grad );

The required elevation must be supplied (in radians). The second
argument indicates whether we are looking for a solution with a
positive (source is rising) or negative (source is setting)
gradient. +1 indicates a rising source, -1 indicates a setting source.

On entry, the C<datetime> method must return a time that is to be used
as the starting point for convergence (the closer the better) On exit,
the C<datetime> method will return the calculated time for that
elevation.

The algorithm used for this routine is very simple. Try not to call it
repeatedly.

=cut

sub _iterative_el {
  my $self = shift;
  my $refel = shift;
  my $grad = shift;

  # See what type of date object we are dealing with
  my $use_dt = $self->_isdt();

  # Calculate current elevation
  my $el = $self->el;

  # Tolerance (1 minute of arc)
  my $tol = ( 30 / 3600 ) * Astro::SLA::DD2R;

  # Get the estimated time for this elevation
  my $time = $self->datetime;

  # now compare the requested elevation with the actual elevation for the
  # previously calculated rise time
  if (abs($el - $refel) > $tol ) {
    if ($DEBUG) {
      print "# ================================ -> ".$self->name."\n";
      print "# Requested elevation: " . (Astro::SLA::DR2D * $refel) ."\n";
      print "# Elevation out of range: ". $self->el(format => 'deg')."\n";
      print "# For " . ($grad > 0 ? "rise" : "set")." time: ". $time->datetime ."\n";
    }

    # use 1 minute for all except the moon
    my $inc = 60; # seconds
    $inc *= 10 if lc($self->name) eq 'moon';

    my $sign = ($el < $refel ? 1 : -1); # incrementing or decrementing time
    my $prevel; # previous elevation

    # This is a very simple convergence algorithm.
    # Newton-Raphson would be much faster given that the function
    # is almost linear for most elevations.
    while (abs($el-$refel) > $tol) {
      if (defined $prevel) {
	# should check sign of gradient to make sure we are not
	# running away to an incorrect gradient

	# see if which way we should be moving
	if ( abs($prevel - $refel) < abs( $el - $refel )) {
	  # the gap between the previous measurement and the reference
	  # is smaller than the current gap. We seem to be diverging.
	  # Change direction
	  $sign *= -1;
	  # and use half the step size
	  $inc /= 2;

	  # in the linear approximation
	  # we know the gradient

	}
      }

      # Now calculate a new time
      my $delta = $sign * $inc;
      if (!$use_dt) {
	$time = $time + $delta;
	# we have created a new object so need to store it for next time
	# round
	$self->datetime( $time );
      } else {
	# increment the time (this happens in place so we do not need to
	# register the change with the datetime method
	$time->add( seconds => "$delta" );
      }
      # recalculate the elevation, storing the previous as reference
      $prevel = $el;
      $el = $self->el;
      print "# New elevation: ". $self->el(format=>'deg')." \t@ ".$time->datetime."\n"
	if $DEBUG;
    }

  }
}

=item B<_isdt>

Internal method. Returns true if the C<datetime> method contains a DateTime
object. Returns false otherwise (assumed to be Time::Piece). If an optional argument
is supplied that argument is tested instead.

  $isdt = $self->_isdt();
  $isdt = $self->_idt( $dt );

=cut

sub _isdt {
  my $self = shift;
  my $test = shift;

  $test = $self->datetime unless defined $test;

  if (blessed( $test ) eq 'DateTime' ) {
    return 1;
  } else {
    return 0;
  }
}


=back

=end __PRIVATE_METHODS__

=head1 NOTES

Many of the methods described in these classes return results as
either C<Astro::Coords::Angle> and C<Astro::Coords::Angle::Hour>
objects. This provides to the caller much more control in how to
represent the answer, especially when the default stringification may
not be suitable.  Whilst methods such as C<radec> and C<apparent>
always return objects, methods to return individual coordinate values
such as C<ra>, C<dec>, and C<az> can return the result in a variety of
formats. The default format is simply to return the underlying
C<Angle> object but an explicit format can be specified if you are
simply interested in the value in degrees, say, or are instantly
stringifying it. The supported formats are all documented in the
C<in_format> method documentation in the C<Astro::Coords::Angle> man
page but include all the standard options that have been available in
early versions of C<Astro::Coords>: 'sexagesimal', 'radians',
'degrees'.

  $radians = $c->ra( format => 'rad' );
  $string  = $c->ra( format => 'sex' );
  $deg     = $c->ra( format => 'deg' );
  $object  = $c->ra();

=head1 CONSTANTS

In some cases when calculating events such as sunrise, sunset or
twilight time it is useful to have predefined constants containing
the standard elevations. These are available in the C<Astro::Coords>
namespace as:

  SUN_RISE_SET: Position of Sun for sunrise or sunset (-50 arcminutes)
  CIVIL_TWILIGHT: Civil twilight (-6 degrees)
  NAUT_TWILIGHT: Nautical twilight (-12 degrees)
  AST_TWILIGHT: Astronomical twilight (-18 degrees)

For example:

  $set = $c->set_time( horizon => Astro::Coords::AST_TWILIGHT );

These are usually only relevant for the Sun. Note that refraction
effects may affect the actual answer and these are simply average
definitions.

For the Sun and Moon the expected defaults are used if no horizon
is specified (ie SUN_RISE_SET is used for the Sun).

=head1 REQUIREMENTS

C<Astro::SLA> is used for all internal astrometric calculations.

=head1 SEE ALSO

L<Astro::Telescope> and L<DateTime> are used to specify observer
location and reference epoch respectively.

L<Astro::Coords::Equatorial>,
L<Astro::Coords::Planet>,
L<Astro::Coords::Fixed>,
L<Astro::Coords::Interpolated>,
L<Astro::Coords::Calibration>,
L<Astro::Coords::Angle>,
L<Astro::Coords::Angle::Hour>.

=head1 AUTHOR

Tim Jenness E<lt>tjenness@cpan.orgE<gt>

=head1 COPYRIGHT

Copyright (C) 2001-2004 Particle Physics and Astronomy Research Council.
All Rights Reserved. This program is free software; you can
redistribute it and/or modify it under the same terms as Perl itself.

=cut

