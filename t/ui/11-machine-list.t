# Copyright (C) 2014 SUSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
  unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA');

# First of all, init the session (this should probably be in OpenQA::Test)
my $req = $t->ua->get('/tests');
my $token = $req->res->dom->at('meta[name=csrf-token]')->attr('content');

#
# No login, no list
$t->get_ok('/admin/machines')->status_is(403);

#
# Not even for operators
$t->delete_ok('/logout')->status_is(302);
$test_case->login($t, 'https://openid.camelot.uk/percival');
$t->get_ok('/admin/machines')->status_is(403);

#
# So let's login as a admin
$t->delete_ok('/logout')->status_is(302);
$test_case->login($t, 'https://openid.camelot.uk/arthur');
$req = $t->get_ok('/admin/machines')->status_is(200);

$req->element_exists('table#machines');
$req->element_exists('#machines tbody td.name');

my $id;
$req->tx->res->dom->find('#machines tbody td.name')->each(sub { my $node = shift; $id = $node->parent->{id} if $node->text eq 'Laptop_64'});
$id =~ s/machine_(\d+)/$1/;
ok($id, "id found");

# check columns
$req->text_is("#machine_$id td.name" => 'Laptop_64');
$req->text_is("#machine_$id td.backend" => 'qemu');
$req->element_exists("#machine_$id td.variables");
# delete one variable link
$req->element_exists("#machine_$id td.variables a[data-method=delete]");

my $delvarhref = $req->tx->res->dom->at("#machine_$id td.variables a[data-method=delete]")->{'href'};
like($delvarhref, qr,^/admin/machines/$id/\d+$,, "delete link ok ok");

say "delete link $delvarhref\n";

# variable combo box, value and add button
$req->element_exists("#machine_$id td.variables input[type=text][name=key]");
$req->element_exists("#machine_$id td.variables datalist");
$req->text_is("#machine_$id td.variables datalist option:nth-child(1)" => 'LAPTOP');
$req->element_exists("#machine_$id td.variables input[type=text][name=value]");
$req->element_exists("#machine_$id td.variables input[type=submit][value=add]");
# test suite delete button
$req->element_exists("#machine_$id td.action a[data-method=delete][href=\"/admin/machines/$id\"]");

$req->text_is("#machine_$id td.variables" => 'LAPTOP=1 QEMUCPU=qemu64');

# delete a variable
$t->delete_ok($delvarhref, { 'X-CSRF-Token' => $token })->status_is(302);

$req = $t->get_ok('/admin/machines')->status_is(200);
$req->text_is("#machine_$id td.variables" => 'QEMUCPU=qemu64');

# delete machine
$t->delete_ok("/admin/machines/$id", { 'X-CSRF-Token' => $token })->status_is(302);

$req = $t->get_ok('/admin/machines')->status_is(200);
$req->element_exists_not("td#machine_$id");

# add a machine, invalid
$req = $t->post_ok('/admin/machines', { 'X-CSRF-Token' => $token }, form => { name => 'foo', whatever => "foobar"})->status_is(200);
$req->element_exists('.ui-state-error');

# add a machine
$req = $t->post_ok('/admin/machines', { 'X-CSRF-Token' => $token },
    form => { name => 'foo', backend => 'bar' })->status_is(302);

say "### here";

$req->element_exists_not('.ui-state-error');
$req = $t->get_ok('/admin/machines')->status_is(200);
$req->element_exists_not('.ui-state-error');

$req->tx->res->dom->find('#machines tbody td.name')->each(sub { my $node = shift; $id = $node->parent->{id} if $node->text eq 'foo'});
$id =~ s/machine_(\d+)/$1/;
ok($id, "id found");

$req->text_is("#machine_$id td.name" => 'foo');
$req->text_is("#machine_$id td.backend" => 'bar');

# add variable
$t->post_ok("/admin/machines/$id", { 'X-CSRF-Token' => $token }, form => { key => 'DESKTOP', value => "dwarf"})->status_is(302);

$req = $t->get_ok('/admin/machines')->status_is(200);
$req->text_is("#machine_$id td.variables" => 'DESKTOP=dwarf');

done_testing();
