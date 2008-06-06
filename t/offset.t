#!perl

use strict;
use Test::More tests => 5;

require_ok("Astro::Coords::Offset");

my $off = Astro::Coords::Offset->new( 55, 22, system => "GALACTIC" );
isa_ok($off, "Astro::Coords::Offset");

is( $off->system, "GAL", "Check system conversion");

$off = Astro::Coords::Offset->new( 55, 22, system => "J2008.5" );
isa_ok($off, "Astro::Coords::Offset");

is( $off->system, "J2008.5", "Check system conversion");
