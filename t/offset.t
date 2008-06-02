#!perl

use strict;
use Test::More tests => 3;

require_ok("Astro::Coords::Offset");

my $off = Astro::Coords::Offset->new( 55, 22, system => "GALACTIC" );
isa_ok($off, "Astro::Coords::Offset");

is( $off->system, "GAL", "Check system conversion");
