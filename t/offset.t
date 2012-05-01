#!perl

use strict;
use Test::More tests => 9;

require_ok("Astro::Coords::Offset");

my $off = Astro::Coords::Offset->new( 55, 22, system => "GALACTIC" );
isa_ok($off, "Astro::Coords::Offset");

is( $off->system, "GAL", "Check system conversion");

$off = Astro::Coords::Offset->new( 55, 22, system => "J2008.5" );
isa_ok($off, "Astro::Coords::Offset");

is( $off->system, "J2008.5", "Check system conversion");

# Check offset rotations against those displayed by the OT.
$off = Astro::Coords::Offset->new(100, 0, posang => 45);
my ($x, $y) = map {$_->arcsec()} $off->offsets_rotated();
is(sprintf('%.1f', $x),  70.7, 'Rotated offset: 100,0,45 x');
is(sprintf('%.1f', $y), -70.7, 'Rotated offset: 100,0,45 y');

$off = Astro::Coords::Offset->new(0, 100, posang => 45);
($x, $y) = map {$_->arcsec()} $off->offsets_rotated();
is(sprintf('%.1f', $x), 70.7, 'Rotated offset, 0,100,45 x');
is(sprintf('%.1f', $y), 70.7, 'Rotated offset, 0,100,45 y');
