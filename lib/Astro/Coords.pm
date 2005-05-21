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

our $VERSION = '0.10';

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

# Number of km in one Astronomical Unit
use constant AU2KM => 149.59787066e6;

# Speed of light ( km/s )
use constant CLIGHT => 2.99792458e5;

# UTC TimeZone
use constant UTC => new DateTime::TimeZone( name => 'UTC' );

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
  $c = new Astro::Coords( elements => \@array );

where C<%elements> must contain the names of the elements
as used in the SLALIB routine slaPlante, and @array is the
contents of the array returned by calling the array() method
on another Elements object.

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
       && (UNIVERSAL::isa($args{elements},"HASH") # A hash
       &&  ((exists $args{elements}{EPOCH}
       and defined $args{elements}{EPOCH})
       ||  (exists $args{elements}{EPOCHPERIH}
       and defined $args{elements}{EPOCHPERIH}))) ||
	( ref($args{elements}) eq 'ARRAY' && # ->array() ref
	  $args{elements}->[0] eq 'ELEMENTS')
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
    return DateTime->now( time_zone => UTC );
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
  my ($sys, $equ) = $self->_parse_equinox( shift || 'J2000' );
  my ($ra_app, $dec_app) = $self->apparent;
  my $mjd = $self->_mjd_tt;
  my ($rm, $dm);
  if ($sys eq 'FK5') {
    # Julian epoch
    Astro::SLA::slaAmp($ra_app, $dec_app, $mjd, $equ, $rm, $dm);
  } elsif ($sys eq 'FK4') {
    # Convert to J2000 and then convert to Besselian epoch
    Astro::SLA::slaAmp($ra_app, $dec_app, $mjd, 2000.0, $rm, $dm);

    ($rm, $dm) = $self->_j2000_to_byyyy( $equ, $rm, $dm);
  }

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
by a subclass this converts the apparent RA/Dec to J2000.

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

=item B<radec2000>

Convenience wrapper routine to return the J2000 coordinates for epoch
2000.0. This is not the same as calling the C<radec> method with
equinox J2000.0.

 ($ra2000, $dec2000) = $c->radec2000;

It is equivalent to setting the epoch in the object to 2000.0
(ie midday on 2000 January 1) and then calling C<radec>.

The answer will be location dependent in most cases.

Results are returned as two C<Astro::Coords::Angle> objects.

=cut

sub radec2000 {
  my $self = shift;

  # store current configuration
  my $reftime = ( $self->has_datetime ? $self->datetime : undef);

  # Create new time
  $self->datetime( DateTime->new( year => 2000, month => 1,
				  day => 1, hour => 12) );

  # Ask for the answer
  my ($ra, $dec) = $self->radec( 'J2000' );

  # restore the date state
  $self->datetime( $reftime );

  return ($ra, $dec);
}

=item B<radec1950>

Convenience wrapper to return the FK4 B1950 coordinates for the
currently defined epoch. Since the FK4 to FK5 conversion requires an
epoch, the J2000 coordinates are first calculated for the current
epoch and the frame conversion is done to epoch B1950.

This is technically not the same as calling the radec() method with
equinox B1950 since that would use the current epoch associated with
the coordinates when converting from FK4 to FK5.

In the base class these are calculated by precessing the J2000 RA/Dec
for the current date and time, which are themselves derived from the
apparent RA/Dec for the current time.

 ($ra, $dec) = $c->radec1950;

Results are returned as two C<Astro::Coords::Angle> objects.

=cut

sub radec1950 {
  my $self = shift;
  my ($ra, $dec) = $self->radec;

  # No E-terms or precession since we are going to B1950 epoch 1950
  Astro::SLA::slaFk54z($ra,$dec,1950.0,my $r1950, 
		       my $d1950, my $dr1950, my $dd1950);

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

Time at which the target will appear above the horizon. By default the calculation is for the next rise time relative to the current reference time. 
If
the "event" key is used, this can control which rise time will be
returned. For event=1, this indicates the following rise (the default),
event=-1 indicates a previous rise and event=0 indicates the nearest
source rising to the current reference time.

If the "nearest" key is set in the argument hash, this is synonymous
with event=0 and supercedes the event key.

Returns C<undef> if the target is never visible or never sets. An
optional argument can be given specifying a different elevation to the
horizon (in radians).

  $t = $c->set_time();
  $t = $c->set_time( horizon => $el );
  $t = $c->set_time( nearest => 1 );
  $t = $c->set_time( event => -1 );

Returns a C<Time::Piece> object or a C<DateTime> object depending on the
type of object that is returned by the C<datetime> method.

For some occasions the calculation will be performed twice, once for
the meridian transit before the reference time and once for the
transit after the reference time.

Does not distinguish a source that never rises from a source that
never sets. Both will return undef for the rise time.

Next and previous depend on the adjacent transits. The routine will
not step forward multiple days looking for a rise time if the source is
not going to rise before the next or previous transit.

=cut

sub rise_time {
  my $self = shift;
  return $self->_rise_set_time( 1, @_);
}

=item B<set_time>

Time at which the target will set below the horizon. By default the
calculation is the next set time from the current reference time. If
the "event" key is used, this can control which set time will be
returned. For event=1, this indicates the following set (the default),
event=-1 indicates a previous set and event=0 indicates the nearest
source setting to the current reference time.

If the "nearest" key is set in the argument hash, this is synonymous
with event=0 and supercedes the event key.

Returns C<undef> if the target is never visible or never sets. An
optional argument can be given specifying a different elevation to the
horizon (in radians).

  $t = $c->set_time();
  $t = $c->set_time( horizon => $el );
  $t = $c->set_time( nearest => 1 );
  $t = $c->set_time( event => -1 );

Returns a C<Time::Piece> object or a C<DateTime> object depending on the
type of object that is returned by the C<datetime> method.

For some occasions the calculation will be performed twice, once for
the meridian transit before the reference time and once for the
transit after the reference time.

Does not distinguish a source that never rises from a source that
never sets. Both will return undef for the set time.

Next and previous depend on the adjacent transits. The routine will
not step forward multiple days looking for a set time if the source is
not going to set following the next or previous transit.

=cut

sub set_time {
  my $self = shift;
  return $self->_rise_set_time( 0, @_);
}


=item B<ha_set>

Hour angle at which the target will set. Negate this value to obtain
the rise time. By default assumes the target sets at an elevation of 0
degrees (except for the Sun and Moon which are special-cased). An
optional hash can be given with key of "horizon" specifying a
different elevation (in radians).

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
    # Calculate transit elevation and if it is greater than the
    # requested "horizon" use an iterative technique to find the
    # set time.
    if ($self->transit_el > $horizon) {
      my $oldtime = ( $self->has_datetime ? $self->datetime : undef);
      my $mt = $self->meridian_time();
      $self->datetime( $mt );
      print "# Calculating iterative set time for HA determination\n"
         if $DEBUG;
      my $convok = $self->_iterative_el( $horizon, -1 );
      return undef unless $convok;
      my $seconds = $self->datetime->epoch - $mt->epoch;
      $cos_ha0 = cos( $seconds * Astro::SLA::DS2R );
      $self->datetime( $oldtime );
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

If you want control over which transit should be calculated this can be 
specified using the "event" hash key:

  $mt = $c->meridian_time( event => 1 );
  $mt = $c->meridian_time( event => 0 );
  $mt = $c->meridian_time( event => -1 );

A value of "1" indicates the next transit following the current
reference time (this is the default behaviour for reasons of backwards
compatibility). A value of "-1" indicates that the closest transit
event before the reference time should be used. A valud of "0"
indicates that the nearest transit event should be returned. If the parameter
value is not one of the above, it will default to "1".

A synonym for event=>0 is provided by using the "nearest" key. If
present and true, this key overrides "event". If present and false the
"event" key is used (defaulting to "1" if event indicates "nearest"=1).

  $mt = $c->meridian_time( nearest => 1 );

=cut

sub meridian_time {
  my $self = shift;
  my %opt = @_;

  # extract the true value of "event" given all the backwards compatibility
  # problems
  my $event = $self->_extract_event( %opt );

  # Get the current time (do not modify it since we need to put it back)
  my $oldtime = ( $self->has_datetime ? $self->datetime : undef);

  # Need a reference time for the calculation
  my $reftime = $self->datetime;

  # For fast moving objects such as planets, we need to calculate
  # the transit time iteratively since the apparent RA/Dec will change
  # slightly during the night so we need to adjust the internal clock
  # to get it close to the actual transit time. We also need to make sure
  # that we are starting at the correct reference time so start at the
  # current time and look forward until we get a transit time > than
  # our start time

  # calculate the required times
  my $mtime;
  if ($event == 1 || $event == -1) {
    # previous or next
    $mtime = $self->_calc_mtime( $reftime, $event );

    # Reset the clock
    $self->datetime( $oldtime );

  } elsif ($event == 0) {
    # nearest requires both
    my $prev = $self->_calc_mtime( $reftime, -1 );
    my $next = $self->_calc_mtime( $reftime,  1 );

    # Reset the clock (before we possibly croak)
    $self->datetime( $oldtime );

    # calculate the diff
    if (defined $prev && defined $next) {
      my $prev_diff = abs( $reftime->epoch - $prev->epoch );
      my $next_diff = abs( $reftime->epoch - $next->epoch );

      if ($prev_diff < $next_diff) {
	$mtime = $prev;
      } else {
	$mtime = $next;
      }

    } elsif (defined $prev) {
      $mtime = $prev;
    } elsif (defined $next) {
      $mtime = $next;
    } else {
      croak "Should not occur in meridian_time\n";
    }
  } else {
    croak "Unrecognized value for event: $event\n";
  }

  return $mtime;
}

sub _calc_mtime {
  my $self = shift;
  my ($reftime, $event ) = @_;

  # event must be 1 or -1
  if (!defined $event || ($event != 1 && $event != -1)) {
    croak "Event must be either +1 or -1";
  }

  # do we have DateTime objects
  my $dtime = $self->_isdt();

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
  my $inc = 12 * $event;
  $inc /= 2 if lc($self->name) eq 'moon';

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

    # make sure we are going the correct way
    # since we are enforced to only find a transit in the direction
    # governed by "event"

    # Calculate the difference in epoch seconds before the current
    # object reference time and the calculate transit time.
    # Use ->epoch rather than overload since I'm having problems
    # with Duration objects
    my $diff = $reftime->epoch - $mtime->epoch;
    $diff *= $event; # make the comparison correct sense
    if ($diff > 0) {
      print "Need to offset....[diff = $diff sec]\n" if $DEBUG;
      # this is an earlier transit time
      # Need to keep jumping forward until we lock on to a meridian
      # time that ismore recent than the ref time
      if ($dtime) {
	$mtime->add( hours => ($count * $inc));
      } else {
	$mtime = $mtime + ($count * $inc * Time::Seconds::ONE_HOUR);
      }
    }

    # End loop if the difference between meridian time and calculated
    # previous time is less than the acceptable tolerance
    if (defined $prevtime && defined $mtime) {
      last if (abs($mtime->epoch - $prevtime->epoch) <= $tol);
    }
  }

  # warn if we did not converge
  warnings::warnif "Meridian time calculation failed to converge"
     if $count > $max;

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
  if ($self->_isdt()) {
    return $datetime->clone->add( seconds => $offset_sec );
  } else {
    return ($datetime + $offset_sec);
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

=head2 Velocities

This sections describes the available methods for determining the velocities
of each of the standard velocity frames in the direction of the reference
target relative to the current observer position and reference time.

=over 4

=item B<rv>

Return the radial velocity of the target (not the observer) in km/s.
This will be used for parallax corrections (if relevant) and for
calculating the doppler correction factor.

  $rv = $c->rv();

If the velocity was originally specified as a redshift it will be
returned here as optical velocity (and may not be a physical value).

If no radial velocity has been specified, returns 0 km/s.

=cut

sub rv {
  my $self = shift;
  return (defined $self->{RadialVelocity} ? $self->{RadialVelocity} : 0 );
}

# internal set routine
sub _set_rv {
  my $self = shift;
  $self->{RadialVelocity} = shift;
}

=item B<redshift>

Redshift is defined as the optical velocity as a fraction of the speed of light:

  v(opt) = c z

Returns the reshift if the velocity definition is optical. If the
velocity definition is radio, redshift can only be calculated for
small radio velocities.  An attempt is made to calculate redshift from
radio velocity using

  v(opt) = v(radio) / ( 1 - v(radio) / c )

but only if v(radio)/c is small. Else returns undef.

=cut

sub redshift {
  my $self = shift;
  my $vd = $self->vdefn;
  if ($vd eq 'REDSHIFT' || $vd eq 'OPTICAL') {
    return ( $self->rv / CLIGHT );
  } elsif ($vd eq 'RELATIVISTIC') {
    # need to add
    return undef;
  } else {
    my $rv = $self->rv;
    # 1% of light speed
    if ( $rv > ( 0.01 * CLIGHT) ) {
      my $vopt = $rv / ( 1 - ( $rv / CLIGHT ) );
      return ( $vopt / CLIGHT );
    } else {
      return undef;
    }
  }
}

# internal set routine
sub _set_redshift {
  my $self = shift;
  my $z = shift;
  $z = 0 unless defined $z;
  $self->_set_rv( CLIGHT * $z );
  $self->_set_vdefn( 'REDSHIFT' );
  $self->_set_vframe( 'HEL' );
}

=item B<vdefn>

The velocity definition used to specify the target radial velocity.
This is a readonly parameter set at object creation (depending on
subclass) and can be one of RADIO, OPTICAL, RELATIVISTIC or REDSHIFT
(which is really optical but specified in a different way).

  $vdefn = $c->vdefn();

Required for calculating the doppler correction. Defaults to 'OPTICAL'.

=cut

sub vdefn {
  my $self = shift;
  return (defined $self->{VelocityDefinition} ? $self->{VelocityDefinition} : 'OPTICAL' );
}

# internal set routine
sub _set_vdefn {
  my $self = shift;
  my $defn = shift;
  # undef resets to default
  if (defined $defn) {
    $defn = $self->_normalise_vdefn( $defn );
  }
  $self->{VelocityDefinition} = $defn;
}

=item B<vframe>

The velocity frame used to specify the radial velocity. This attribute is readonly
and set during object construction. Abbreviations are used for the first 3 characters
of the standard frames (4 to distinguish LSRK from LSRD):

  HEL  - Heliocentric (the Sun)
  GEO  - Geocentric   (Centre of the Earth)
  TOP  - Topocentric  (Surface of the Earth)
  LSR  - Kinematical Local Standard of Rest
  LSRK - As for LSR
  LSRD - Dynamical Local Standard of Rest

The usual definition for star catalogues is Heliocentric. Default is Heliocentric.

=cut

sub vframe {
  my $self = shift;
  return (defined $self->{VelocityFrame} ? $self->{VelocityFrame} : 'HEL' );
}

# internal set routine
sub _set_vframe {
  my $self = shift;
  my $frame = shift;
  if (defined $frame) {
    # undef resets to default
    $frame = $self->_normalise_vframe( $frame );
  }
  $self->{VelocityFrame} = $frame;
}

=item B<obsvel>

Calculates the observed velocity of the target as seen from the
observer's location. Includes both the observer velocity and target
velocity.

 $rv = $c->obsvel;

Note that the source velocity and observer velocity are simply added
without any regard for relativistic effects for high redshift sources.

=cut

sub obsvel {
  my $self = shift;
  my $vdefn = $self->vdefn;
  my $vframe = $self->vframe;
  my $rv = $self->rv;

  # Now we need to calculate the observer velocity in the
  # target frame
  my $vobs = $self->vdiff( '', 'TOPO' );

  # Total velocity between observer and target
  my $vtotal = $vobs + $rv;

  return $vtotal;
}

=item B<doppler>

Calculates the doppler factor required to correct a rest frequency to
an observed frequency. This correction is calculated for the observer
location and specified date and uses the velocity definition provided
to the object constructor. Both the observer radial velocity, and the
target radial velocity are taken into account (see the C<obsvel>
method).

  $dopp = $c->doppler;

Default definitions and frames will be used if none were specified.

The doppler factors (defined as  frequency/rest frequency or 
rest wavelength / wavelength) are calculated as follows:

 RADIO:    1 - v / c

 OPTICAL   1 - v / ( v + c )

 REDSHIFT  ( 1 / ( 1 + z ) ) * ( 1 - v(hel) / ( v(hel) + c ) )

ie in order to observe a line in the astronomical target, multiply the
rest frequency by the doppler correction to select the correct frequency
at the telescope to tune the receiver.

For high velocity optical sources ( v(opt) << c ) and those sources
specified using redshift, the doppler correction is properly
calculated by first correcting the rest frequency to a redshifted
frequency (dividing by 1 + z) and then separately correcting for the
telescope motion relative to the new redshift corrected heliocentric
rest frequency. The REDSHIFT equation, above, is used in this case and
is used if the source radial velocity is > 0.01 c. ie the Doppler
correction is calculated for a source at 0 km/s Heliocentric and
combined with the redshift correction.

The Doppler correction is invalid for large radio velocities.

=cut

sub doppler {
  my $self = shift;
  my $vdefn = $self->vdefn;
  my $obsvel = $self->obsvel;

  # Doppler correction depends on definition
  my $doppler;
  if ( $vdefn eq 'RADIO' ) {
    $doppler = 1 - ( $obsvel / CLIGHT );
  } elsif ( $vdefn eq 'OPTICAL' || $vdefn eq 'REDSHIFT' ) {
    if ( $obsvel > (0.01 * CLIGHT)) {
      # Relativistic velocity
      # First calculate the redshift correction
      my $zcorr = 1 / ( 1 + $self->redshift );

      # Now the observer doppler correction to Heliocentric frame
      my $vhel = $self->vhelio;
      my $obscorr = 1 - ( $vhel / ( CLIGHT * $vhel) );

      $doppler = $zcorr * $obscorr;

    } else {
      # small radial velocity, use standard doppler formula
      $doppler = 1 - ( $obsvel / ( CLIGHT + $obsvel ) );
    }
  } elsif ( $vdefn eq 'RELATIVISTIC' ) {
    # do we need to use the same correction as for OPTICAL and REDSHIFT?
    # presumably
    $doppler = sqrt( ( CLIGHT - $obsvel ) / ( CLIGHT + $obsvel ) );
  } else {
    croak "Can not calculate doppler correction for unsupported definition $vdefn\n";
  }
  return $doppler;
}

=item B<vdiff>

Simple wrapper around the individual velocity methods (C<vhelio>, C<vlsrk> etc)
to report the difference in velocity between two arbitrary frames.

  $vd = $c->vdiff( 'HELIOCENTRIC', 'TOPOCENTRIC' );
  $vd = $c->vdiff( 'HEL', 'LSRK' );

Note that the velocity methods all report their velocity relative to the
observer (ie topocentric correction), equivalent to specifiying 'TOPO'
as the second argument to vdiff.

The two arguments are mandatory but if either are 'undef' they are converted
to the target velocity frame (see C<vdefn> method).

The second example is simply equivalent to 

  $vd = $c->vhelio - $c->vlsrk;

but the usefulness of this method really comes into play when defaulting to
the target frame since it removes the need for logic in the main program.

  $vd = $c->vdiff( 'HEL', '' );

=cut

sub vdiff {
  my $self = shift;
  my $f1 = ( shift || $self->vframe );
  my $f2 = ( shift || $self->vframe );

  # convert the arguments to standardised frames
  $f1 = $self->_normalise_vframe( $f1 );
  $f2 = $self->_normalise_vframe( $f2 );

  return 0 if $f1 eq $f2;

  # put all the supported answers in a hash relative to TOP
  my %vel;
  $vel{TOP} = 0;
  $vel{GEO} = $self->verot();
  $vel{HEL} = $self->vhelio;
  $vel{LSRK} = $self->vlsrk;
  $vel{LSRD} = $self->vlsrd;
  $vel{GAL}  = $self->vgalc;
  $vel{LG}   = $self->vlg;

  # now the difference is easy
  return ( $vel{$f1} - $vel{$f2} );
}

=item B<verot>

The velocity component of the Earth's rotation in the direction of the
target (in km/s).

  $vrot = $c->verot();

Current time will be assumed if none is set. If no observer location
is specified, the equator at 0 deg lat will be used.

=cut

sub verot {
  my $self = shift;

  # Local Sidereal Time
  my $lst = $self->_lst;

  # Observer location
  my $tel = $self->telescope;
  my $lat = (defined $tel ? $tel->lat : 0 );

  # apparent ra dec
  my ($ra, $dec) = $self->apparent();

  return Astro::SLA::slaRverot( $lat, $ra, $dec, $lst );
}

=item B<vorb>

Velocity component of the Earth's orbit in the direction of the target
(in km/s) for the current date and time.

  $vorb = $c->vorb;

=cut

sub vorb {
  my $self = shift;

  # Earth velocity (and position)
  my @vb = (0,0,0);
  my @pb = (0,0,0);
  my @vh = (0,0,0);
  my @ph = (0,0,0);
  Astro::SLA::slaEvp($self->_mjd_tt(), 2000.0,@vb,@pb,@vh,@ph);

  # Convert spherical source coords to cartesian
  my ($ra, $dec) = $self->radec;
  my @cart = (0,0,0);
  Astro::SLA::slaDcs2c($ra,$dec,@cart);

  # Velocity due to Earth's orbit is scalar product of the star position
  # with the Earth's heliocentric velocity
  my $vorb = - Astro::SLA::slaDvdv(@cart,@vh)* AU2KM;
  return $vorb;
}

=item B<vhelio>

Velocity of the observer with respect to the Sun in the direction of
the target (ie the heliocentric frame).  This is simply the sum of the
component due to the Earth's orbit and the component due to the
Earth's rotation.

 $vhel = $c->vhelio;

=cut

sub vhelio {
  my $self = shift;
  return ($self->verot + $self->vorb);
}

=item B<vlsrk>

Velocity of the observer with respect to the kinematical Local Standard
of Rest in the direction of the target.

  $vlsrk = $c->vlsrk();

=cut

sub vlsrk {
  my $self = shift;
  my ($ra, $dec) = $self->radec;
  return (Astro::SLA::slaRvlsrk( $ra, $dec ) + $self->vhelio);
}

=item B<vlsrd>

Velocity of the observer with respect to the dynamical Local Standard
of Rest in the direction of the target.

  $vlsrd = $c->vlsrd();

=cut

sub vlsrd {
  my $self = shift;
  my ($ra, $dec) = $self->radec;
  return (Astro::SLA::slaRvlsrd( $ra, $dec ) + $self->vhelio);
}

=item B<vgalc>

Velocity of the observer with respect to the centre of the Galaxy
in the direction of the target.

  $vlsrd = $c->vgalc();

=cut

sub vgalc {
  my $self = shift;
  my ($ra, $dec) = $self->radec;
  return (Astro::SLA::slaRvgalc( $ra, $dec ) + $self->vlsrd);
}

=item B<vgalc>

Velocity of the observer with respect to the Local Group in the
direction of the target.

  $vlsrd = $c->vlg();

=cut

sub vlg {
  my $self = shift;
  my ($ra, $dec) = $self->radec;
  return (Astro::SLA::slaRvlg( $ra, $dec ) + $self->vhelio);
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
			         time_zone => UTC );
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
  my $e1 = (defined $t1 ? $t1->epoch : 0);
  my $e2 = (defined $t2 ? $t2->epoch : 0);
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

=item B<_rise_set_time>

Return either the rise time or set time associated with a specific horizon.

  $time = $c->_rise_set_time( $rise, %opt );

Where the options hash controls the horizon and whether the event
should follow the reference time, come before the reference time or be
the nearest event.

Supported keys for event control are processed by the _extract_event
private method.

$rise should be true if the source is rising, and false if the source
is setting.

=cut

sub _rise_set_time {
  my $self = shift;
  my $rise = shift;
  my %opt = @_;

  # Calculate the HA required for setting
  my $ha_set = $self->ha_set( %opt, format=> 'radians' );
  return if ! defined $ha_set;

  # extract the event information
  my $event = $self->_extract_event( %opt );

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

  # somewhere to store the times
  my @times;

  # Calculate the set or rise time for both the previous and next meridian time
  # so that we can work out which set time to return. There is probably
  # an analytic short cut that can be used to decide whether the
  # correct set time will be related to the previous or next meridian
  # time simply by calculating the meridian time once and shifting
  # it by 24 hours

  for my $n (-1, 1) {
    # Calculate the transit time
    print "Calculating " .($n == -1 ? "previous" : "next") . " meridian time\n"
      if $DEBUG;
    my $mt = $self->meridian_time( event => $n );

    # First guestimate for the event
    my $event_time;
    if ($rise) {
      $event_time = $mt - $ha_set;
    } else {
      $event_time = $mt + $ha_set;
    }

    # Now converge about this value
    $self->datetime( $event_time );
    my $convok = $self->_iterative_el( $refel, ($rise ? 1 : -1) );
    $event_time = ( $convok ? $self->datetime : undef );
    print "**** Failed to converge\n" if ($DEBUG && !$convok);

    # and restore the reference date to reset the clock
    $self->datetime( ( $havetime ? $reftime : undef ) );

    # store the event time
    push(@times, $event_time) if defined $event_time;

    print "Determined ".($rise ? "rise" : "set" ) . " time of ".
       (defined $event_time ? $event_time : 'undef')."\n"
       if $DEBUG;
  }

  # choose a value
  my $event_time;
  if ($event == -1) {
    # We want the nearest time that is earlier than reference time
    # Start from the end and jump out when 
    for my $t (reverse @times) {
      if ($t->epoch <= $reftime->epoch) {
	$event_time = $t;
	last;
      }
    }
  } elsif ($event == 1) {
    # start from the oldest until we hit a new time
    for my $t (@times) {
      if ($t->epoch >= $reftime->epoch) {
	$event_time = $t;
	last;
      }
    }
  } elsif ($event == 0) {
    # calculate the diff
    my %diffs = map { abs( $reftime->epoch - $_->epoch), $_ } @times;
    my @sort = sort { $a <=> $b } keys %diffs;
    $event_time = $diffs{$sort[0]};

  } else {
    croak "Unrecognized event specifier in set_time";
  }


  return $event_time;
}


=item B<_iterative_el>

Use an iterative technique to calculate the time the object passes through
a specified elevation. This routine is used for non-sidereal objects (especially
the moon and fast asteroids) where a simple calculation assuming a sidereal
object may lead to inaccuracies of a few minutes (maybe even 10s of minutes).
It is called by both C<set_time> and C<rise_time> to converge on an accurate
time of elevation.

  $status = $self->_iterative_el( $refel, $grad );

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

Returns undef if the routine did not converge.

=cut

sub _iterative_el {
  my $self = shift;
  my $refel = shift;
  my $grad = shift;

  # See what type of date object we are dealing with
  my $use_dt = $self->_isdt();

  # Calculate current elevation
  my $el = $self->el;

  # Tolerance (in arcseconds)
  my $tol = 5 * Astro::SLA::DAS2R;

  # smallest support increment
  my $smallinc = 0.2;

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

    # Indicate whether we have straddled the correct answer
    my $has_been_high;
    my $has_been_low;

    # This is a very simple convergence algorithm.
    # Newton-Raphson would be much faster given that the function
    # is almost linear for most elevations.
    while (abs($el-$refel) > $tol) {
      if (defined $prevel) {

	# should check sign of gradient to make sure we are not
	# running away to an incorrect gradient. Note that this function
	# can be highly curved if we are near ante transit.

	# There are two constraints that have to be used to control
	# the convergence
	#  - make sure we are not diverging with each iteration
	#  - make sure we are not bouncing around missing the final
	#    value due to inaccuracies in the time resolution (this is
	#    important for fast moving objects like the sun). Currently
	#    we are not really doing anything useful by tweaking by less
	#    than a second

	# The problem is that we can not stop on bracketing the correct
	# value if we are never going to reach the value itself because
	# it never rises or never sets

	#          \   /
	#           \ /
	#            -   <--  minimum elevation
	#                <--  required elevation

	# in the above case each step will diverge but will never
	# straddle

	# The solution is to first iterate by using a divergence
	# criterion. Then, if we determine that we have straddled the
	# correct result, we switch to a stopping criterion that
	# uses the time resolution if we never fully converge (the
	# important thing is to return a time not an elevation)

	my $diff_to_prev = $prevel - $refel;
	my $diff_to_curr = $el - $refel;

	# set the straddle parameters
	if ($diff_to_curr < 0) {
	  $has_been_low = 1;
	} else {
	  $has_been_high = 1;
	}

	# if we have straddled, stop on increment being small

	# now determine whether we should reverse
	# if we know we are bouncing around the correct value
	# we can reverse as soon as the previous el and the current el
	# are either side of the correct answer
	my $reverse;
	if ($has_been_low && $has_been_high) {
	  # we can abort if we are below the time resolution
	  last if $inc < $smallinc;

	  # reverse 
	  $reverse = 1 if ($diff_to_prev / $diff_to_curr < 0);
	} else {
	  # abort if the inc is too small
	  return undef if $inc < $smallinc;

	  # if we have not straddled, we reverse if the previous el
	  # is closer than this el
	  $reverse = 1 if abs($diff_to_prev) < abs($diff_to_curr);
	}

	# if the increment is small, bounce


	# reverse
	if ( $reverse ) {

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
	if (abs($delta) > 1) {
	  $time->add( seconds => "$delta" );
	} else {
	  $time->add( nanoseconds => ( $delta * 1E9 ) );
	}

      }
      # recalculate the elevation, storing the previous as reference
      $prevel = $el;
      $el = $self->el;
      print "# New elevation: ". $self->el(format=>'deg')." \t@ ".$time->datetime." with delta $delta sec\n"
	if $DEBUG;
    }

  }
  return 1;
}

=item B<_isdt>

Internal method. Returns true if the C<datetime> method contains a
DateTime object. Returns false otherwise (assumed to be
Time::Piece). If an optional argument is supplied that argument is
tested instead.

  $isdt = $self->_isdt();
  $isdt = $self->_isdt( $dt );

=cut

sub _isdt {
  my $self = shift;
  my $test = shift;

  $test = $self->datetime unless defined $test;

  # Check Time::Piece first since there is a possibility that 
  # this is really a subclass of DateTime
  my $dtime;
  if ($test->isa( "Time::Piece")) {
    $dtime = 0;
  } elsif ($test->isa("DateTime")) {
    $dtime = 1;
  } else {
    croak "Unknown DateTime object class ". blessed($test);
  }

  return $dtime;
}

=item B<_extract_event>

Parse an options hash to determine the correct value of the "event" key
given backwards compatibility requirements.

  $event = $self->_extract_event( %opt );

 - "nearest" trumps "event" if "nearest" is true. Returns event=0

 - If "event" is not defined, it defaults to "1"

 - If "nearest" is false, "event" is used unless "event"=0 in
   which case "nearest" trumps "event" and returns "1".

=cut

sub _extract_event {
  my $self = shift;

  # make sure the $opt{event} always exists
  my $default = 1;
  my %opt = (event => $default, @_);

  if (exists $opt{nearest}) {
    if ($opt{nearest}) {
      # request for nearest
      return 0;
    } else {
      # request for not nearest
      if ($opt{event} == 0) {
	# this is incompatible with nearest=0 so return default
	return $default;
      } else {
	return $opt{event};
      }
    }

  } else {
    return $opt{event};
  }
}

=item B<_normalise_vframe>

Convert an input string representing a velocity frame, to
a standardised form recognized by the software. In most cases,
the string is upper cased and reduced two the first 3 characters.
LSRK and LSRD are special-cased. LSR is converted to LSRK.

 $frame = $c->_normalise_vframe( $in );

Unrecognized or undefined frames trigger an exception.

=cut

sub _normalise_vframe {
  my $self = shift;
  my $in = shift;

  croak "Velocity frame not defined. Can not normalise" unless defined $in;

  # upper case
  $in = uc( $in );

  # LSRK or LSRD need no normalisation
  return $in if ($in eq 'LSRK' || $in eq 'LSRD' || $in eq 'LG');

  # Truncate
  my $trunc = substr( $in, 0, 3 );

  # Verify
  croak "Unrecognized velocity frame '$trunc'"
    unless $trunc =~ /^(GEO|TOP|HEL|LSR|GAL)/;

  # special case
  $trunc = 'LSRK' if $trunc eq 'LSR';

  # okay
  return $trunc;
}

=item B<_normalise_vdefn>

Convert an input string representing a velocity definition, to
a standardised form recognized by the software. In all cases the
string is truncated to 3 characters and upper-cased before validating
against known types.

 $defn = $c->_normalise_vdefn( $in );

Unrecognized or undefined frames trigger an exception.

=cut

sub _normalise_vdefn {
  my $self = shift;
  my $in = shift;

  croak "Velocity definition not defined. Can not normalise" unless defined $in;

  # upper case
  $in = uc( $in );

  # Truncate
  my $trunc = substr( $in, 0, 3 );

  # Verify
  if ($trunc eq 'RAD') {
    return 'RADIO';
  } elsif ($trunc eq 'OPT') {
    return 'OPTICAL';
  } elsif ($trunc eq 'RED') {
    return 'REDSHIFT';
  } elsif ($trunc eq 'REL') {
    return 'RELATIVISTIC';
  } else {
    croak "Unrecognized velocity definition '$trunc'";
  }
}

=item B<_parse_equinox>

Given an equinox string of the form JYYYY.frac or BYYYY.frac
return the epoch of the equinox and the system of the equinox.

  ($system, $epoch ) = $c->_parse_equinox( 'B1920.34' );

If no leading letter, Julian epoch is assumed. If the string does not
match the reuquired pattern, J2000 will be assumed and a warning will
be issued.

System is returned as 'FK4' for Besselian epoch and 'FK5' for
Julian epoch.

=cut

sub _parse_equinox {
  my $self = shift;
  my $str = shift;
  my ($sys, $epoch) = ('FK5', 2000.0);
  if ($str =~ /^([BJ]?)(\d+(\.\d+)?)$/i) {
    my $typ = $1;
    $sys = ($typ eq 'B' ? 'FK4' : 'FK5' );
    $epoch = $2;
  } else {
    warnings::warnif( "Supplied equinox '$str' does not look like an equinox");
  }
  return ($sys, $epoch);
}

=item B<_j2000_to_byyyy>

Since we always store in J2000 internally, converting between
different Julian equinoxes is straightforward. This routine takes a
J2000 coordinate pair (with proper motions and parallax already
applied) and converts them to Besselian equinox for the current epoch.

  ($bra, $bdec) = $c->_j2000_to_BYYY( $equinox, $ra2000, $dec2000);

The equinox is the epoch year. It is assumed to be Besselian.

=cut

sub _j2000_to_byyyy {
  my $self = shift;
  my ($equ, $ra2000, $dec2000) = @_;

  # First to 1950
  Astro::SLA::slaFk54z($ra2000, $dec2000, 
		       Astro::SLA::slaEpb( $self->_mjd_tt ),
		       my $rb, my $db, my $drb, my $drd);

  # Then preces to reference epoch frame
  # I do not know whether fictitious proper motions should be included
  # here with slaPm or whether it is enough to use non-1950 epoch
  # in slaFk54z and then preces 1950 to the same epoch. Not enough test
  # data for this rare case.
  if ($equ != 1950) {
    # Add E-terms
    Astro::SLA::slaSubet( $rb, $db, 1950.0, my $rnoe, my $dnoe);

    # preces
    Astro::SLA::slaPreces( 'FK4', 1950, $equ, $rnoe, $dnoe);

    # Add E-terms
    Astro::SLA::slaAddet( $rnoe, $dnoe, $equ, $rb, $db);

  }
  return ($rb, $db);
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

Copyright (C) 2001-2005 Particle Physics and Astronomy Research Council.
All Rights Reserved.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful,but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc., 59 Temple
Place,Suite 330, Boston, MA  02111-1307, USA

=cut

