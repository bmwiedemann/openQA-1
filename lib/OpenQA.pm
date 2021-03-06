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

package OpenQA;
use Mojo::Base 'Mojolicious';
use openqa 'connect_db';
use OpenQA::Helpers;
use Scheduler;
use Mojo::IOLoop;
use DateTime;
use Cwd qw/abs_path/;

use Config::IniFiles;

sub _read_config {
    my $self = shift;

    my %defaults = (
        global => {
            base_url => undef,
            branding => "openSUSE",
            allowed_hosts => undef,
            suse_mirror => undef,
            scm => 'git',
            hsts => 365,
        },
        'scm git' => {
            do_push => 'no',
        },
        logging => {
            level => undef,
            file => "/var/log/openqa",
        },
        openid => {
            provider => 'https://www.opensuse.org/openid/user/',
            httpsonly => '1',
        },
        hypnotoad => {
            listen => ['http://localhost:9526/'],
            proxy => 1,
        },
    );

    # Mojo's built in config plugins suck. JSON for example does not
    # support comments
    my $cfg = Config::IniFiles->new(-file => $ENV{OPENQA_CONFIG} || $self->app->home.'/lib/openqa.ini') || undef;

    for my $section (sort keys %defaults) {
        for my $k (sort keys %{$defaults{$section}}) {
            my $v = $cfg && $cfg->val($section, $k);
            $v = $defaults{$section}->{$k} unless defined $v;
            $self->app->config->{$section}->{$k} = $v if defined $v;
        }
    }
    $self->app->config->{_openid_secret} = $self->rndstr(16);
}

# check if have worker dead then clean up its job
sub _workers_checker {
    my $self = shift;

    # Start recurring timer, check workers alive every 20 mins
    my $id = Mojo::IOLoop->recurring(
        1200 => sub {
            my $dt = DateTime->now(time_zone=>'UTC');
            my $threshold = join ' ',$dt->ymd, $dt->hms;

            Mojo::IOLoop->timer(
                10 => sub {
                    my $dead_jobs = Scheduler::jobs_get_dead_worker($threshold);
                    foreach my $job (@$dead_jobs) {
                        my %args = (
                            jobid => $job->{id},
                            result => 'incomplete',
                        );
                        my $result = Scheduler::job_set_done(%args);
                        if($result) {
                            Scheduler::job_duplicate(jobid => $job->{id});
                            print STDERR "cancelled dead job $job->{id} and re-duplicated done\n";
                        }
                    }
                }
            );
        }
    );
}

# reinit pseudo random number generator in every child to avoid
# starting off with the same state.
sub _init_rand{
    my $self = shift;
    return unless $ENV{HYPNOTOAD_APP};
    Mojo::IOLoop->timer(
        0 => sub {
            srand;
            $self->app->log->debug("initialized random number generator in $$");
        }
    );
}

has schema => sub {
    return connect_db();
};

has secrets => sub {
    my $self = shift;
    # read application secret from database
    # we cannot use our own schema here as we must not actually
    # initialize the db connection here. Would break for prefork.
    my @secrets = $self->schema->resultset('Secrets')->all();
    if (!@secrets) {
        # create one if it doesn't exist
        $self->schema->resultset('Secrets')->create({});
        @secrets = $self->schema->resultset('Secrets')->all();
    }
    die "couldn't create secrets\n" unless @secrets;
    my $ret = [ map { $_->secret } @secrets ];
    return $ret;
};

# This method will run once at server start
sub startup {
    my $self = shift;

    # Set some application defaults
    $self->defaults( appname => 'openQA' );

    unshift @{$self->renderer->paths}, '/etc/openqa/templates';

    # Documentation browser under "/perldoc"
    $self->plugin('PODRenderer');
    $self->plugin('OpenQA::Helpers');
    $self->plugin('OpenQA::CSRF');
    $self->plugin('OpenQA::REST');

    # set secure flag on cookies of https connections
    $self->hook(
        before_dispatch => sub {
            my $c = shift;
            #$c->app->log->debug(sprintf "this connection is %ssecure", $c->req->is_secure?'':'NOT ');
            if ($c->req->is_secure) {
                $c->app->sessions->secure(1);
            }
            if (my $days = $c->app->config->{global}->{hsts}) {
                $c->res->headers->header('Strict-Transport-Security', sprintf 'max-age=%d; includeSubDomains', $days*24*60*60);
            }
        }
    );

    $self->_read_config;

    if ($ENV{OPENQA_LOGFILE}) {
        $self->log->path($ENV{OPENQA_LOGFILE});
    }
    elsif ($self->config->{'logging'}->{'file'}) {
        $self->log->path($self->config->{'logging'}->{'file'});
    }
    if ($self->config->{'logging'}->{'level'}) {
        $self->log->level($self->config->{'logging'}->{'level'});
    }

    $self->plugin(
        CHI => {
            ThumbCache => {
                driver     => 'CacheCache',
                cc_class   => 'Cache::FileCache',
                cc_options => {
                    cache_root  => abs_path($openqa::cachedir),
                    directory_umask => 077,
                },
            },
            default => {
                driver => 'Memory',
                global => 1
            },
            namespaces => 1
        }
    );
    # clear thumbnails cache when openqa started
    $self->chi('ThumbCache')->clear();

    # Router
    my $r = $self->routes;
    my $auth = $r->bridge('/')->to("session#ensure_operator");

    $r->get('/session/new')->to('session#new');
    $r->post('/session')->to('session#create');
    $r->delete('/session')->to('session#destroy');
    $r->get('/login')->name('login')->to('session#create');
    $r->post('/login')->to('session#create');
    $r->delete('/logout')->name('logout')->to('session#destroy');
    $r->get('/response')->to('session#response');
    $auth->get('/session/test')->to('session#test');

    my $apik_auth = $auth->route('/api_keys');
    $apik_auth->get('/')->name('api_keys')->to('api_key#index');
    $apik_auth->post('/')->to('api_key#create');
    $apik_auth->delete('/:apikeyid')->name('api_key')->to('api_key#destroy');

    $r->get('/tests')->name('tests')->to('test#list');
    $r->get('/tests/overview')->name('tests_overview')->to('test#overview');
    my $test_r = $r->route('/tests/:testid', testid => qr/\d+/);
    my $test_auth = $auth->route('/tests/:testid', testid => qr/\d+/, format => 0 );
    $test_r->get('/')->name('test')->to('test#show');
    $test_auth->get('/menu')->name('test_menu')->to('test#menu');

    $r->get('/workers')->name('workers')->to('worker#list');

    $test_r->get('/modlist')->name('modlist')->to('running#modlist');
    $test_r->get('/status')->name('status')->to('running#status');
    $test_r->get('/livelog')->name('livelog')->to('running#livelog');
    $test_r->get('/streaming')->name('streaming')->to('running#streaming');
    $test_r->get('/edit')->name('edit_test')->to('running#edit');

    my $log_auth = $r->bridge('/tests/#testid')->to("session#ensure_authorized_ip");
    $log_auth->post('/uploadlog/#filename')->name('uploadlog')->to('test#uploadlog');

    $test_r->get('/images/#filename')->name('test_img')->to('file#test_file');
    $test_r->get('/images/thumb/#filename')->name('test_thumbnail')->to('file#test_thumbnail');
    $test_r->get('/file/#filename')->name('test_file')->to('file#test_file');
    $test_r->get('/data')->name('test_data')->to('file#test_data');
    $test_r->get('/diskimages/:imageid')->name('diskimage')->to('file#test_diskimage');
    $test_r->get('/iso')->name('isoimage')->to('file#test_isoimage');
    # adding assetid => qr/\d+/ doesn't work here. wtf?
    $test_r->get('/asset/#assetid')->name('test_asset_id')->to('file#test_asset');
    $test_r->get('/asset/#assettype/#assetname')->name('test_asset_name')->to('file#test_asset');
    $test_r->get('/asset/#assettype/#assetname/*subpath')->name('test_asset_name_path')->to('file#test_asset');

    my $step_r = $test_r->route('/modules/:moduleid/steps/:stepid', stepid => qr/[1-9]\d*/)->to(controller => 'step');
    my $step_auth = $test_auth->route('/modules/:moduleid/steps/:stepid', stepid => qr/[1-9]\d*/);
    $step_r->get('/view')->to(action => 'view');
    $step_r->get('/edit')->name('edit_step')->to(action => 'edit');
    $step_r->get('/src')->name('src_step')->to(action => 'src');
    $step_auth->post('/')->name('save_needle')->to('step#save_needle');
    $step_r->get('/')->name('step')->to(action => 'view');

    $r->get('/needles/:distri/#name')->name('needle_file')->to('file#needle');

    # Favicon
    $r->get('/favicon.ico' => sub {my $c = shift; $c->render_static('favicon.ico') });
    # Default route
    $r->get(
        '/' => sub {
            my $c = shift;
            $c->render(template => 'pages/index');
        }
    )->name('index');

    # Redirection for old links to openQAv1
    $r->get(
        '/results' => sub {
            my $c = shift;
            $c->redirect_to('tests');
        }
    );

    #
    ## Admin area starts here
    ###
    my $admin_auth = $r->bridge('/admin')->to("session#ensure_admin");
    my $admin_r = $admin_auth->route('/')->to(namespace => 'OpenQA::Admin');

    $admin_r->get('/users')->name('admin_users')->to('user#index');
    $admin_r->post('/users/:userid')->name('admin_user')->to('user#update');

    $admin_r->get('/products')->name('admin_products')->to('product#index');
    $admin_r->post('/products')->to('product#create');
    $admin_r->delete('/products/:product_id')->name('admin_product')->to('product#destroy');
    $admin_r->post('/products/:product_id')->name('admin_product_setting_post')->to('product#add_variable');
    $admin_r->delete('/products/:product_id/:settingid')->name('admin_product_setting_delete')->to('product#remove_variable');

    $admin_r->get('/machines')->name('admin_machines')->to('machine#index');
    $admin_r->post('/machines')->to('machine#create');
    $admin_r->delete('/machines/:machine_id')->name('admin_machine')->to('machine#destroy');
    $admin_r->post('/machines/:machine_id')->name('admin_machine_setting_post')->to('machine#add_variable');
    $admin_r->delete('/machines/:machine_id/:settingid')->name('admin_machine_setting_delete')->to('machine#remove_variable');

    $admin_r->get('/test_suites')->name('admin_test_suites')->to('test_suite#index');
    $admin_r->post('/test_suites')->to('test_suite#create');
    $admin_r->delete('/test_suites/:test_suite_id')->name('admin_test_suite')->to('test_suite#destroy');
    $admin_r->post('/test_suites/:test_suite_id')->name('admin_test_suite_setting_post')->to('test_suite#add_variable');
    $admin_r->delete('/test_suites/:test_suite_id/:settingid')->name('admin_test_suite_setting_delete')->to('test_suite#remove_variable');

    $admin_r->get('/job_templates')->name('admin_job_templates')->to('job_template#index');
    $admin_r->post('/job_templates')->to('job_template#update');

    $admin_r->get('/assets')->name('admin_assets')->to('asset#index');

    # Users list as default option
    $admin_r->get('/')->name('admin')->to('user#index');
    ###
    ## Admin area ends here
    #

    #
    ## JSON API starts here
    ###
    my $api_auth = $r->bridge('/api/v1')->to(controller => 'API::V1', action => 'auth');
    my $api_r = $api_auth->route('/')->to(namespace => 'OpenQA::API::V1');
    my $api_public_r = $r->route('/api/v1')->to(namespace => 'OpenQA::API::V1');

    # api/v1/jobs
    $api_public_r->get('/jobs')->name('apiv1_jobs')->to('job#list'); # list_jobs
    $api_r->post('/jobs')->name('apiv1_create_job')->to('job#create'); # job_create
    $api_r->post('/jobs/restart')->name('apiv1_restart_jobs')->to('job#restart');

    my $job_r = $api_r->route('/jobs/:jobid', jobid => qr/\d+/);
    $api_public_r->route('/jobs/:jobid', jobid => qr/\d+/)->get('/')->name('apiv1_job')->to('job#show'); # job_get
    $job_r->delete('/')->name('apiv1_delete_job')->to('job#destroy'); # job_delete
    $job_r->post('/prio')->name('apiv1_job_prio')->to('job#prio'); # job_set_prio
    $job_r->post('/result')->name('apiv1_job_result')->to('job#result'); # job_update_result
    $job_r->post('/set_done')->name('apiv1_set_done')->to('job#done'); # job_set_done

    # job_set_waiting, job_set_continue
    my $command_r = $job_r->route('/set_:command', command => [qw(waiting continue)]);
    $command_r->post('/')->name('apiv1_set_command')->to('job#set_command');
    # restart and cancel are valid both by job id or by job name (which is
    # exactly the same, but with less restrictive format)
    my $job_name_r = $api_r->route('/jobs/#name');
    $job_name_r->post('/restart')->name('apiv1_restart')->to('job#restart'); # job_restart
    $job_name_r->post('/cancel')->name('apiv1_cancel')->to('job#cancel'); # job_cancel
    $job_name_r->post('/duplicate')->name('apiv1_duplicate')->to('job#duplicate'); # job_duplicate

    # api/v1/workers
    $api_public_r->get('/workers')->name('apiv1_workers')->to('worker#list'); # list_workers
    $api_r->post('/workers')->name('apiv1_create_worker')->to('worker#create'); # worker_register
    my $worker_r = $api_r->route('/workers/:workerid', workerid => qr/\d+/);
    $api_public_r->route('/workers/:workerid', workerid => qr/\d+/)->get('/')->name('apiv1_worker')->to('worker#show'); # worker_get
    $worker_r->get('/commands/')->name('apiv1_commands')->to('command#list'); #command_get
    $worker_r->post('/commands/')->name('apiv1_create_command')->to('command#create'); #command_enqueue
    $worker_r->delete('/commands/:commandid')->name('apiv1_delete_command')->to('command#destroy'); #command_dequeue
    $worker_r->post('/grab_job')->name('apiv1_grab_job')->to('job#grab'); # job_grab

    # api/v1/isos
    $api_r->post('/isos')->name('apiv1_create_iso')->to('iso#create'); # iso_new
    $api_r->delete('/isos/#name')->name('apiv1_destroy_iso')->to('iso#destroy'); # iso_delete
    $api_r->post('/isos/#name/cancel')->name('apiv1_cancel_iso')->to('iso#cancel'); # iso_cancel

    # api/v1/assets
    $api_r->post('/assets')->name('apiv1_post_asset')->to('asset#register');
    $api_public_r->get('/assets')->name('apiv1_get_asset')->to('asset#list');
    $api_public_r->get('/assets/#id')->name('apiv1_get_asset_id')->to('asset#get');
    $api_public_r->get('/assets/#type/#name')->name('apiv1_get_asset_name')->to('asset#get');
    $api_r->delete('/assets/#id')->name('apiv1_delete_asset')->to('asset#delete');
    $api_r->delete('/assets/#type/#name')->name('apiv1_delete_asset_name')->to('asset#delete');

    # json-rpc methods not migrated to this api: echo, list_commands
    ###
    ## JSON API ends here
    #

    # start workers checker
    $self->_workers_checker;
    $self->_init_rand;
}

1;
# vim: set sw=4 et:
