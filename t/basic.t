use strict;
use Test;

BEGIN { plan tests => 9 }

use Astro::Coords;
use Astro::Telescope;
use Time::Object;

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

# No tests for elements yet
