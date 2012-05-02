#!perl

use strict;
use Test::More tests => 20;
use Data::Dumper;

require_ok("Astro::Coords");
require_ok("Astro::Telescope");
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

my $coords = Astro::Coords->new(type => 'J2000',
  ra => 1.2, dec => 0.22, name => 'Test');
my $tel = new Astro::Telescope('JCMT');
my $date = new DateTime(year => 2012, month => 4, day => 1,
  hour => 19, minute => 45, second => 59);
$coords->telescope($tel);
$coords->datetime($date);
$off = Astro::Coords::Offset->new(0, 0);
my $coordsoff = $coords->apply_offset($off);

my $dd1 = new Data::Dumper([$coords]);
my $dd2 = new Data::Dumper([$coordsoff]);
$dd1->Sortkeys(1);
$dd2->Sortkeys(1);
is($dd1->Dump(), $dd2->Dump(), 'Before and after offset: no change');

$off = new Astro::Coords::Offset(
  new Astro::Coords::Angle(0.001, unit => 'radians'),
  new Astro::Coords::Angle(0.001, unit => 'radians'));

# Check if the coordinates are nearly just those with the
# offsets added directly
$coordsoff = $coords->apply_offset($off);
ok(nearly_equal($coordsoff->ra2000()->radians(), 1.201), 'After offset, RA');
ok(nearly_equal($coordsoff->dec2000()->radians(), 0.221), 'After offset, DEC');

sub nearly_equal {
  my ($a, $b) = @_;
  return abs($a - $b) < 0.0001;
}

# Test on other coordinate systems


my ($o, $c)= new Astro::Coords::Offset(0, 0);

$c = new Astro::Coords(planet => 'venus');
print STDERR "\nShould see a warning about planets.\n";
$c->apply_offset($o);

eval {
  $c = new Astro::Coords(az => 345, el => 45);
  $c->apply_offset($o);
};
ok($@ =~ /^apply_offset/, 'Can not offset fixed coordinates');

eval {
  $c = new Astro::Coords();
  $c->apply_offset($o);
};
ok($@ =~ /^apply_offset/, 'Can not offset calibrations');


$c = new Astro::Coords(mjd1 => 50000, mjd2 => 50000,
                       ra1 => 1.2, dec1 => 0.4,
                       ra2 => 1.3, dec2 => 0.5,
                       units => 'radians');
print STDERR "\nShould see a warning about interpolated coordinates.\n";
$c->apply_offset($o);

$c = new Astro::Coords(elements => {
                                     # from JPL horizons, from t/basic.t
                                     EPOCH => 52440.0000,
                                     EPOCHPERIH => 50538.179590069,
                                     ORBINC => 89.4475147* &Astro::PAL::DD2R,
                                     ANODE =>  282.218428* &Astro::PAL::DD2R,
                                     PERIH =>  130.7184477* &Astro::PAL::DD2R,
                                     AORQ => 0.9226383480674554,
                                     E => 0.9949722217794675,
                                    },
                      name => "Hale-Bopp");
print STDERR "\nShould see a warning about orbital elements.\n";
$c->apply_offset($o);

$c = new Astro::Coords(long => '05:22:56.00',
                       lat  => '-06:20:40.40',
                       type => 'galactic');
my $cc = $c->apply_offset(new Astro::Coords::Offset(10, 0, system => 'GAL'));
my ($glon, $glat) = map {$_->in_format('sex')} $cc->glonglat();
ok($glon =~ /^05:23:06/, 'galactic long');
is($glat, '-06:20:40.40', 'galactic lat no change');

$cc = $c->apply_offset(new Astro::Coords::Offset(0, 10, system => 'GAL'));
($glon, $glat) = map {$_->in_format('sex')} $cc->glonglat();
is($glon, '05:22:56.00', 'galactic long no change');
is($glat, '-06:20:30.40', 'galactic lat');
