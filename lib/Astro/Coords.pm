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

  # Return coordinates J2000, for the epoch stored in the datetime
  # object. This will work for all variants.
  $ra = $c->ra();
  $dec = $c->dec();

  # Return coordinates J2000, epoch 2000.0
  $ra = $c->ra2000();
  $dec = $c->dec2000();

  # Return coordinats apparent, reference epoch, from location
  # In sexagesimal format.
  $ra_app = $c->ra_app( format => 's');
  $dec_app = $c->dec_app( format => 's' );

  # Azimuth and elevation for reference epoch from observer location
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

  # Calculate the set time of the source
  $t = $c->set_time;


=head1 DESCRIPTION

Class for manipulating and transforming astronomical coordinates.
Can handle the following coordinate types:

  + Equatorial RA/Dec, galactic (including proper motions and parallax)
  + Planets
  + Comets/Asteroids
  + Fixed locations in azimuth and elevations

For time dependent calculations a telescope location and reference
time must be provided.

=cut

use 5.006;
use strict;
use warnings;
use warnings::register;
use Carp;
use vars qw/ $DEBUG /;
$DEBUG = 0;

our $VERSION = '0.07';

use Math::Trig qw/ acos /;
use Astro::SLA ();
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

=back

=head2 General Methods

=over 4

=item B<ra_app>

Apparent RA for the current time. Arguments are similar to those
specified for "dec_app".

  $ra_app = $c->ra_app( format => "s" );

=cut

sub ra_app {
  my $self = shift;
  my %opt = @_;
  $opt{format} = "radians" unless defined $opt{format};
  my $ra = ($self->_apparent)[0];
  # Convert to hours if we are using a string or hour format
  $ra = $self->_cvt_tohrs( \$opt{format}, $ra);
  return $self->_cvt_fromrad( $ra, $opt{format});
}


=item B<dec_app>

Apparent Dec for the currently stored time. Arguments are similar to those
specified for "dec".

  $dec_app = $c->dec_app( format => "s" );

=cut

sub dec_app {
  my $self = shift;
  my %opt = @_;
  $opt{format} = "radians" unless defined $opt{format};
  return $self->_cvt_fromrad( ($self->_apparent)[1], $opt{format});
}

=item B<ha>

Get the hour angle for the currently stored LST. Default units are in
radians.

  $ha = $c->ha;
  $ha = $c->ha( format => "h" );

If you wish to normalize the Hour Angle to +/- 12h use the
normalize key.

  $ha = $c->ha( normalize => 1 );

=cut

sub ha {
  my $self = shift;
  my %opt = @_;
  $opt{format} = "radians" unless defined $opt{format};
  my $ha = $self->_lst - $self->ra_app;
  # Normalize to +/-pi
  $ha = Astro::SLA::slaDrange( $ha )
    if $opt{normalize};

  # Convert to hours if we are using a string or hour format
  $ha = $self->_cvt_tohrs( \$opt{format}, $ha);
  return $self->_cvt_fromrad( $ha, $opt{format});
}

=item B<az>

Azimuth of the source for the currently stored time at the current
telescope. Arguments are similar to those specified for "dec".

  $az = $c->az();

If no telescope is defined the equator is used.

=cut

sub az {
  my $self = shift;
  my %opt = @_;
  $opt{format} = "radians" unless defined $opt{format};
  return $self->_cvt_fromrad( ($self->_azel)[0], $opt{format});
}

=item B<el>

Elevation of the source for the currently stored time at the current
telescope. Arguments are similar to those specified for "dec".

  $el = $c->el();

If no telescope is defined the equator is used.

=cut

sub el {
  my $self = shift;
  my %opt = @_;
  $opt{format} = "radians" unless defined $opt{format};
  return $self->_cvt_fromrad( ($self->_azel)[1], $opt{format});
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

=item B<ra>

Return the J2000 Right ascension for the target. Unless overridden
by a subclass this converts the apparrent RA/Dec to J2000.

  $ra2000 = $c->ra( format => "s" );

=cut

sub ra {
  my $self = shift;
  my %opt = @_;
  $opt{format} = "radians" unless defined $opt{format};
  my ($ra_app, $dec_app) = $self->_apparent;
  my $mjd = $self->_mjd_tt;
  Astro::SLA::slaAmp($ra_app, $dec_app, $mjd, 2000.0, my $rm, my $dm);
  # Convert to hours if we are using a string or hour format
  $rm = $self->_cvt_tohrs( \$opt{format}, $rm);
  return $self->_cvt_fromrad( $rm, $opt{format});
}

=item B<dec>

Return the J2000 declination for the target. Unless overridden
by a subclass this converts the apparrent RA/Dec to J2000.

  $dec2000 = $c->dec( format => "s" );

=cut

sub dec {
  my $self = shift;
  my %opt = @_;
  $opt{format} = "radians" unless defined $opt{format};
  my ($ra_app, $dec_app) = $self->_apparent;
  my $mjd = $self->_mjd_tt;
  Astro::SLA::slaAmp($ra_app, $dec_app, $mjd, 2000.0, my $rm, my $dm);
  return $self->_cvt_fromrad( $dm, $opt{format});
}

=item B<pa>

Parallactic angle of the source for the currently stored time at the
current telescope. Arguments are similar to those specified for "dec".

  $pa = $c->pa();

If no telescope is defined the equator is used.

=cut

sub pa {
  my $self = shift;
  my %opt = @_;
  $opt{format} = "radians" unless defined $opt{format};
  my $ha = $self->ha;
  my $dec = $self->dec_app;
  my $tel = $self->telescope;
  my $lat = ( defined $tel ? $tel->lat : 0.0);
  return $self->_cvt_fromrad(Astro::SLA::slaPa($ha, $dec, $lat), $opt{format});
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

The distance is returned in radians (but should be some form of angular
object as should all of the RA and dec coordinates). In list context returns
the individual "x" and "y" offsets (in radians). In scalar context returns the
distance.

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
    return ($xi, $eta);
  } else {
    return ($xi**2 + $eta**2)**0.5;
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

    $string .= "Elevation:      " . $self->el(format=>'d')." deg\n";
    $string .= "Azimuth  :      " . $self->az(format=>'d')." deg\n";
    my $ha = Astro::SLA::slaDrange( $self->ha ) * Astro::SLA::DR2H;
    $string .= "Hour angle:     " . $ha ." hrs\n";
    $string .= "Apparent RA :   " . $self->ra_app(format=>'s')."\n";
    $string .= "Apparent dec:   " . $self->dec_app(format=>'s')."\n";

    # Transit time
    $string .= "Time of next transit:" . $self->meridian_time ."\n";
    $string .= "Transit El:     " . $self->transit_el(format=>'d')." deg\n";
    my $ha_set = $self->ha_set( format => 'hour');
    $string .= "Hour Ang. (set):" . (defined $ha_set ? $ha_set : '??')." hrs\n";

    my $t = $self->rise_time;
    $string .= "Next Rise time:      " . $t . "\n" if defined $t;
    $t = $self->set_time;
    $string .= "Next Set time:       " . $t . "\n" if defined $t;

    # This check was here before we added a RA/Dec to the
    # base class.
    if ($self->can('ra')) {
      $string .= "RA (J2000):     " . $self->ra(format=>'s')."\n";
      $string .= "Dec(J2000):     " . $self->dec(format=>'s')."\n";
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

  $string .= "For time ". $self->datetime ."\n";
  my $fmt = 's';
  $string .= "LST: ". $self->_cvt_fromrad($self->_cvt_tohrs(\$fmt,$self->_lst),$fmt) ."\n";

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

The angles are in the units specified (radians, degrees or sexagesimal).

Note that this method returns C<DateTime> objects if it was given C<DateTime>
objects, else it returns C<Time::Piece> objects.

=cut

sub calculate {
  my $self = shift;

  my %opts = @_;

  croak "No start time specified" unless exists $opts{start};
  croak "No end time specified" unless exists $opts{end};
  croak "No time increment specified" unless exists $opts{inc};

  # Get the increment as an integer (DateTime::Duration or Time::Seconds)
  my $inc = $opts{inc};
  if (UNIVERSAL::can($inc, "seconds")) {
    $inc = $inc->seconds;
  }
  croak "Increment must be greater than zero" unless $inc > 0;

  $opts{units} = 'rad' unless exists $opts{units};

  # Determine date class to use for calculations
  my $dateclass = blessed( $opts{start} );
  croak "Start time must be either Time::Piece or DateTime object"
    if (!$dateclass || 
	($dateclass ne "Time::Piece" && $dateclass ne 'DateTime' ));

  my @data;

  # Get a private copy of the date object for calculations
  # (copy constructor)
  my $current = _clone_time( $opts{start} );

  while ( $current->epoch <= $opts{end}->epoch ) {

    # Hash for storing the data
    my %timestep;

    # store a copy of the time
    $timestep{time} = _clone_time( $current );

    # Set the time in the object
    # [standard problem with knowing whether we are overriding
    # another setting]
    $self->datetime( $current );

    # Now calculate the positions
    $timestep{elevation} = $self->el( format => $opts{units} );
    $timestep{azimuth} = $self->az( format => $opts{units} );
    $timestep{parang} = $self->pa( format => $opts{units} );
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

  $t = $c->rise_time( nearest => 1 );

Returns a C<Time::Piece> object.

BUG: Does not distinguish a source that never rises from a source
that never sets.

=cut

sub rise_time {
  my $self = shift;
  my %opts = @_;

  # Calculate the HA required for setting
  my $ha_set = $self->ha_set( %opts, format => 'radians' );
  return if ! defined $ha_set;

  # and convert to seconds
  $ha_set *= Astro::SLA::DR2S;

  # Calculate the transit time
  my $mt = $self->meridian_time( nearest => $opts{nearest} );

  if (blessed($mt) eq 'DateTime') {
    $ha_set = new DateTime::Duration( seconds => $ha_set );
  }

  # Calculate rise time by subtracting the hour angle
  my $rise = $mt - $ha_set;

  # For non-sidereal sources we need to use this as a starting
  # point for iteration
  # Get the current time (do not modify it since we need to put it back)
  my $reftime = $self->datetime;

  # Determine whether we have to remember the cache
  my $havetime = $self->has_datetime;

  # Store the rise time
  $self->datetime( $rise );

  # Requested elevation
  my $refel = ( exists $opts{horizon} ? $opts{horizon} : 0);

  # Calculate current elevation
  my $el = $self->el;

  # Tolerance (1 minute of arc)
  my $tol = ( 1 / 60 ) * Astro::SLA::DD2R;

  if (abs($el - $refel) > $tol ) {
    print "================================".$self->name."\n";
    print "Requested elevation: " . (Astro::SLA::DR2D * $refel) ."\n";
    print "Elevation out of range: ". $self->el(format => 'deg')."\n";
    print "For rise time: $rise\n";

    my $inc = 60; # seconds
    my $sign = ($el < $refel ? 1 : -1); # incrementing or decremeing time
    while (abs($el-$refel) > $tol) {
      if ($el > $refel) {
	# Need to go backwards in time
	if ($sign != -1) {
	  # we have gone too far. Decrease increment
	  $inc /= 2;
	}
	$sign = -1;
      } else {
	# need to go forward in time
	if ($sign != 1) {
	  # we have gone too far. Decrease increment
	  $inc /= 2;
	}
	$sign = 1;
      }
      my $delta = $sign * $inc;
      if ($rise->isa("Time::Piece")) {
	$rise = $rise + $delta;
      } else {
	$rise->add( new DateTime::Duration( seconds => $delta ));
      }
      $self->datetime( $rise );
      $el = $self->el;
      print "New elevation: ". $self->el(format=>'deg')."\n";
      print "New time: $rise\n";
    }

  }


  # Reset the clock
  if ($havetime) {
    $self->datetime( $reftime );
  } else {
    $self->datetime( undef );
  }

  # If the rise time has already happened return undef
  # unless we are allowing earlier times
  if (!$opts{nearest}) {
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

Returns a C<Time::Piece> object.

BUG: Does not distinguish a source that never rises from a source
that never sets.

BUG: Since C<meridian_time> returns the next transit, and this method
uses that meridian time, it is possible that you will be returned the
set time after next.

=cut

sub set_time {
  my $self = shift;

  # Calculate the HA required for setting
  my $ha_set = $self->ha_set( @_, format=> 'radians' );
  return if ! defined $ha_set;

  # and convert to seconds
  $ha_set *= Astro::SLA::DR2S;

  # and thence to a duration if required
  if ($self->datetime->isa('DateTime')) {
    $ha_set = new DateTime::Duration( seconds => $ha_set );
  }


  my $set;
  # Calculate first for nearest meridian and then for
  # next meridian. We want the set time to be in our future.
  for my $n (1, 0) {
    # Calculate the transit time
    my $mt = $self->meridian_time( nearest => $n );

    $set = $mt + $ha_set;

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

Returned in radians, unless overridden with the "format" key.
(See the C<ha> method for alternatives).

  $ha = $c->ha_set( horizon => $el, format => 'h');

There are predefined elevations for events such as 
Sun rise/set and Twilight (only relevant if your object
refers to the Sun). See L<"Constants"> for more information.

Returns C<undef> if the target never reaches the specified horizon.
(maybe it is circumpolar).

=cut

sub ha_set {
  my $self = shift;

  # Get the reference horizon elevation
  my %opt = @_;

  $opt{horizon} = 0 unless defined $opt{horizon};
  $opt{format}  = 'radians' unless defined $opt{format};

  # Get the telescope position
  my $tel = $self->telescope;

  # Get the longitude (in radians)
  my $lat = (defined $tel ? $tel->lat : 0.0 );

  # Declination
  my $dec = $self->dec_app;

  # Calculate the hour angle for this elevation
  # See http://www.faqs.org/faqs/astronomy/faq/part3/section-5.html
  my $cos_ha0 = ( sin($opt{horizon}) - sin($lat)*sin( $dec ) ) /
    ( cos($lat) * cos($dec) );

  # Make sure we have a valid number for the cosine
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
  $ha0 = $self->_cvt_tohrs( \$opt{format}, $ha0);
  return $self->_cvt_fromrad( $ha0, $opt{format});
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
  my %opts = @_;

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
  print "Looping..............$reftime\n" if $DEBUG;
  while ( $count <= $max ) {
    $count++;

    if (defined $mtime) {
      $prevtime = _clone_time( $mtime );
      $self->datetime( $mtime );
    }
    $mtime = $self->_local_mtcalc();
    print "New meridian time: $mtime\n" if $DEBUG;

    # if we want to make sure we have the next transit, we need
    # to compare the calculated time with the reference time
    if (!$opts{nearest}) {

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

Format is supported as for the C<el> method.

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

=item B<_lst>

Calculate the LST for the current date/time and
telescope and return it (in radians).

If no date/time is specified the current time will be used.
If no telescope is defined the LST will be from Greenwich.

This is labelled as an internal routine since it is not clear whether
the method to determine LST should be here or simply placed into
C<Time::Object>. In practice this simply calls the
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
  return (Astro::SLA::ut2lst( $time->year, $time->mon,
			      $time->mday, $time->hour,
			      $time->min, $time->sec, $long))[0];

}

=item B<_azel>

Return Azimuth and elevation for the currently stored time and telescope.
If no telescope is present the equator is used.

=cut

sub _azel {
  my $self = shift;
  my $ha = $self->ha;
  my $dec = $self->dec_app;
  my $tel = $self->telescope;
  my $lat = ( defined $tel ? $tel->lat : 0.0);
  Astro::SLA::slaDe2h( $ha, $dec, $lat, my $az, my $el );
  return ($az, $el);
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

=over 4

=item B<_cvt_tohrs>

Scale a value in radians such that it can be translated
correctly to hours by routines that are assuming output is
required in degrees (effectively dividing by 15).

  $radhr = $c->_cvt_tohrs( \$format, $rad );

Format is modified to reflect the change expected by
C<_cvt_fromrad()>. 

=cut

sub _cvt_tohrs {
  my $self = shift;
  my ($fmt, $rad) = @_;
  # Convert to hours if we are using a string or hour format
  $rad /= 15.0 if defined $rad && $$fmt =~ /^[ash]/;
  # and reset format to use degrees
  $$fmt = "degrees" if $$fmt =~ /^h/;
  return $rad;
}

=item B<_cvt_fromrad>

Convert the supplied value (in radians) to the desired output
format. Output options are:

 sexagesimal - A string of format either dd:mm:ss
 radians     - The default (no change)
 degrees     - decimal degrees
 array       - return a reference to an array containing the
               sign/degrees/minutes/seconds

If the output is required in hours, pre-divide the radians by 15.0
prior to calling this routine.

  $out = $c->_cvt_fromrad( $rad, $format );

If the input value is undefined the return value will be undefined.

=cut

sub _cvt_fromrad {
  my $self = shift;
  my $in = shift;
  my $format = shift;
  $format = '' unless defined $format;
  return $in unless defined $in;

  if ($format =~ /^d/) {
    $in *= Astro::SLA::DR2D;
  } elsif ($format =~ /^[as]/) {
    my @dmsf;
    my $res = 2;
    Astro::SLA::slaDr2af($res, $in, my $sign, @dmsf);
    if ($format =~ /^a/) {
      # Store the sign
      unshift(@dmsf, $sign);
      # Combine the fraction [assuming fixed precision]
      my $frac = pop(@dmsf);
      $dmsf[-1] .= sprintf( ".%0$res"."d",$frac);
      # Store the reference
      $in = \@dmsf;
    } else {
      $sign = ' ' if $sign eq "+";
      $in = $sign . sprintf("%02d:%02d:%02d.%0$res"."d",@dmsf);
    }
  }

  return $in;
}

=item B<_cvt_torad>

Convert from the supplied units to radians. The following
units are supported:

 sexagesimal - A string of format either dd:mm:ss or "dd mm ss"
 degrees     - decimal degrees
 radians     - radians
 hours       - decimal hours

If units are not supplied (undef) default is to assume "sexagesimal"
if the supplied string contains spaces or colons, "degrees" if the
supplied number is greater than 2*PI (6.28), and "radians" for all
other values.

  $radians = Astro::Coords::Equatorial->_cvt_torad("sexagesimal",
                                                   "5:22:63")

An optional final argument can be used to indicate that the supplied
string is in hours rather than degrees. This is only used when
units is set to "sexagesimal". Warnings are issued if the
string can not be parsed or the values are out of range.

Returns undef on error.

=cut

# probably need to use a hash argument

sub _cvt_torad {
  my $self = shift;
  my $units = shift;
  my $input = shift;
  my $hms = shift;

  return undef unless defined $input;

  # Clean up the string
  $input =~ s/^\s+//g;
  $input =~ s/\s+$//g;

  # guess the units
  unless (defined $units) {

    # Now if we have a space or : then we have a real string
    if ($input =~ /(:|\s)/) {
      $units = "sexagesimal";
    } elsif ($input > Astro::SLA::D2PI) {
      $units = "degrees";
    } else {
      $units = "radians";
    }

  }

  # Now process the input - starting with strings
  my $output = 0;
  if ($units =~ /^s/) {

    # Need to clean up the string for slalib
    $input =~ s/:/ /g;

    my $nstrt = 1;
    Astro::SLA::slaDafin( $input, $nstrt, $output, my $j);
    $output = undef unless $j == 0;

    if ($j == -1) {
      warnings::warnif "In coordinate '$input' the degrees do not look right";
    } elsif ($j == -2) {
      warnings::warnif "In coordinate '$input' the minutes field is out of range";
    } elsif ($j == -3) {
      warnings::warnif "In coordinate '$input' the seconds field is out of range (0-59.9)";
    } elsif ($j == 1) {
      warnings::warnif "Unable to find plausible coordinate in string '$input'";
    }

    # If we were in hours we need to multiply by 15
    $output *= 15.0 if (defined $output && $hms);

  } elsif ($units =~ /^h/) {
    # Hours in decimal
    $output = $input * Astro::SLA::DH2R;

  } elsif ($units =~ /^d/) {
    # Degrees decimal
    $output = $input * Astro::SLA::DD2R;

  } else {
    # Already in radians
    $output = $input;
  }

  return $output;
}

=item B<_mjd_tt>

Retrieve the MJD in TT (Terrestrial time) rather than UTC time.

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

Compares two times (assuming the same class)

  $cmp = _cmp_time( $a, $b );

Returns 1 if $a > $b (epoch)
       -1 if $a < $b (epoch)
        0 if $a == $b (epoch)

Currently assumes epoch is enough for comparison.

=cut

sub _cmp_time {
  my $t1 = shift;
  my $t2 = shift;
  my $e1 = $t1->epoch;
  my $e2 = $t2->epoch;
  return $e1 <=> $e2;
}

=back

=end __PRIVATE_METHODS__

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

=head1 REQUIREMENTS

C<Astro::SLA> is used for all internal astrometric calculations.

=head1 AUTHOR

Tim Jenness E<lt>tjenness@cpan.orgE<gt>

=head1 COPYRIGHT

Copyright (C) 2001-2003 Particle Physics and Astronomy Research Council.
All Rights Reserved. This program is free software; you can
redistribute it and/or modify it under the same terms as Perl itself.

=cut

