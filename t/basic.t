use strict;
use Test;

BEGIN { plan tests => 70 }

use Astro::Coords;
use Astro::Telescope;
use Time::Piece ':override';

# Simulataneously test negative zero dec and B1950 to J2000 conversion
my $c = new Astro::Coords( ra => "15:22:33.3",
	                   dec => "-0:13:4.5",
			   type => "B1950");

print "#J2000: $c\n";
# Compare with J2000 values
ok("15:25:7.35", $c->ra(format=>'s'));
ok("-0:23:35.76", $c->dec(format=>'s'));

# Set telescope
my $tel = new Astro::Telescope('JCMT');
my $ukirt = new Astro::Telescope('UKIRT');

# Date/Time
# Something we know
# Approx Fri Sep 14 02:57 2001
my $date = gmtime(1000436215);

# Configure the object
$c->telescope( $tel );
$c->datetime( $date);

# Test Az/El
ok( int($c->el(format=>"d")), 67.0 );
ok( int($c->az(format=>"d")), 208.0 );

# Get the summary
my @result = ("RADEC",4.03660853577072,-0.00686380910209873,undef,
	      undef,undef,undef,undef,undef,undef,undef);
my @summary = $c->array;
test_array_elem(\@summary,\@result);

# observability
ok( $c->isObservable );

# Change telescope and try again
$c->telescope( $ukirt );
ok( $c->isObservable );

# Now for a planet
$c = new Astro::Coords( planet => "mars" );
$c->telescope( $tel );
$c->datetime( $date);

print "# $c\n";
# Test stringify
ok("$c", "MARS");

# Test Az/El
ok( int($c->el(format=>"d")),  34 );
ok( int($c->az(format=>"d")), 145 );

# And apparent ra/dec
ok( int($c->ra_app(format=>"h")), 18);
ok( int($c->dec_app(format=>"d")), -26);

# Get the summary
@result = ("mars",undef,undef,undef,undef,undef,undef,undef,undef,
	      undef,undef);
@summary = $c->array;
test_array_elem(\@summary,\@result);

# observability
ok( $c->isObservable );


# No tests for elements yet

# Test Fixed on Earth coordinate frames
# and compare with the previous values for Mars

my $fc = new Astro::Coords( az => $c->az, el => $c->el );
$fc->telescope( $tel );
$fc->datetime( $date);

print "# FIXED: $fc\n";

ok($fc->type, "FIXED");

# Test Az/El
ok( int($fc->el(format=>"d")),  34 );
ok( int($fc->az(format=>"d")), 145 );

# And apparent ra/dec
ok( int($fc->ra_app(format=>"h")), 18);
ok( int($fc->dec_app(format=>"d")), -26);

# Get the summary
@result = ("FIXED",$fc->az,$fc->el,undef,undef,undef,undef,undef,undef,
	      undef,undef);
@summary = $fc->array;
test_array_elem(\@summary,\@result);

# observability
ok( $fc->isObservable );


# Calibration
print "# CAL\n";
my $cal = new Astro::Coords();

ok( $cal->type, "CAL");

# observability
ok( $cal->isObservable );


# Now come up with some coordinates that are not 
# always observable

print "# Observability\n";

$c = new Astro::Coords( ra => "15:22:33.3",
			dec => "-0:13:4.5",
			type => "J2000");

$c->telescope( $tel );
$c->datetime( $date ); # approximately transit
ok( $c->isObservable );

# Change the date by 12 hours
# Approx Fri Sep 14 14:57 2001
my $ndate = gmtime(1000436215 + ( 12*3600) );
$c->datetime( $ndate );
ok(! $c->isObservable );

# switch to UKIRT (shouldn't be observable either)
$c->telescope( $ukirt );
ok( ! $c->isObservable );

# Now use coordinates which can be observed with JCMT
# but not with UKIRT
$c = new Astro::Coords( ra => "15:22:33.3",
			dec => "72:13:4.5",
			type => "J2000");

$c->telescope( $tel );
$c->datetime( $date );

ok( $c->isObservable );
$c->telescope( $ukirt );
ok( !$c->isObservable );


# Some random comparisons with SCUBA headers
print "# Compare with SCUBA observations\n";


$c = new Astro::Coords( planet => 'mars');
$c->telescope( $tel );

my $time = _gmstrptime("2002-03-21T03:16:36");
$c->datetime( $time);
print "#LST " . ($c->_lst * Astro::SLA::DR2H). "\n";
ok(sprintf("%.1f",$c->az(format => 'd')), '268.5');
ok(sprintf("%.1f",$c->el(format => 'd')), '60.3');

# Done as planet now redo it as interpolated
$c = new Astro::Coords( mjd1 => 52354.13556712963,
			mjd2 => 52354.1459837963,
			ra1  => '02:44:26.06',
			dec1 => '016:24:56.44',
			ra2  => '+002:44:27.77',
			dec2 => '+016:25:04.61',
		      );
$c->telescope( $tel );

$time = _gmstrptime("2002-03-21T03:16:36");
$c->datetime( $time);
print "#LST " . ($c->_lst * Astro::SLA::DR2H). "\n";
ok(sprintf("%.1f",$c->az(format => 'd')), '268.5');
ok(sprintf("%.1f",$c->el(format => 'd')), '60.3');


$c = new Astro::Coords( ra => '04:42:53.60',
			type => 'J2000',
			dec => '36:06:53.65',
			units => 'sexagesimal',
		      );
$c->telescope( $tel );

# Time is in UT not localtime
$time = _gmstrptime("2002-03-21T06:23:36");
$c->datetime( $time );
print "#LST " . ($c->_lst * Astro::SLA::DR2H). "\n";

ok(sprintf("%.1f",$c->az(format => 'd')), '301.7');
ok(sprintf("%.1f",$c->el(format => 'd')), '44.9');

# Comet Hale Bopp
$c = new Astro::Coords( elements => {
				     # Original
				     EPOCH => '1997 Apr 1.1373',
				     ORBINC => 89.4300* Astro::SLA::DD2R,
				     ANODE =>  282.4707* Astro::SLA::DD2R,
				     PERIH =>  130.5887* Astro::SLA::DD2R,
				     AORQ => 0.914142,
				     E => 0.995068,

				     # from JPL horizons
				     EPOCH => 50538.179590069,
				     ORBINC => 89.4475147* Astro::SLA::DD2R,
				     ANODE =>  282.218428* Astro::SLA::DD2R,
				     PERIH =>  130.7184477* Astro::SLA::DD2R,
				     AORQ => 0.9226383480674554,
				     E => 0.9949722217794675,
				    });
ok($c);
$c->telescope( $tel );

# Time is in UT not localtime
$time = _gmstrptime("1997-10-24T16:58:32");
$time = _gmstrptime("1997-10-24T16:57:12");
$time = _gmstrptime("1997-10-24T18:00:00");

$c->datetime( $time );
print "# MJD: " . $c->datetime->mjd ."\n";
print "# LST " . ($c->_lst * Astro::SLA::DR2H). "\n";

# Answer actually stored in the headers is 187.4az and 22.2el
ok(sprintf("%.2f",$c->az(format => 'd')), '187.35');
ok(sprintf("%.3f",$c->el(format => 'd')), '22.168');
print "# RA: " . $c->ra_app(format => 's') . "\n";
print "# Dec: " . $c->dec_app(format => 's') . "\n";




exit;

sub test_array_elem {
  my $ansref  = shift;  # The answer you got
  my $testref = shift;  # The answer you should have got

  # Compare sizes
  ok($#$ansref, $#$testref);

  for my $i (0..$#$testref) {
    ok($ansref->[$i], $testref->[$i]);
  }

}

sub _gmstrptime {
  # parse ISO date as UT
  my $input = shift;
  my $isoformat = "%Y-%m-%dT%T";
  my $time = Time::Piece->strptime($input, $isoformat);
  my $tzoffset = $time->tzoffset;
  return scalar(gmtime($time->epoch() + $tzoffset));
}
