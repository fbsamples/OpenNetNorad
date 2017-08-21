#! /usr/bin/python3

# Copyright (c) 2017-present, Facebook, Inc.
# All rights reserved.

# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree. An additional grant 
# of patent rights can be found in the PATENTS file in the same directory.

import atexit
import logging
import logging.handlers
import os

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.interval import IntervalTrigger
from datetime import datetime, timedelta
from flask import Flask, request
from flask import jsonify
from flask_sqlalchemy import SQLAlchemy

# Amount of minutes we are waiting to consider a ponger death.
DEATH_TIMER = 30

syslog = logging.handlers.SysLogHandler(address='/dev/log')
syslog.setLevel(logging.DEBUG)
syslog.setFormatter(logging.Formatter('pong_logger: %(levelname)s - %(message)s'))

logger = logging.getLogger('pong-logger')
logger.setLevel(logging.DEBUG)
logger.addHandler(syslog)

basedir = os.path.abspath(os.path.dirname(__file__))
app = Flask(__name__)
"""
With this configuration, the app expects the sqlite db to be in the same base
directory, this might not be your desired setup, change the SQLALCHEMY_DATABASE_URI
to a proper location.
"""
app.config.update(dict(
    SQLALCHEMY_DATABASE_URI='sqlite:///' + os.path.join(basedir, 'app.sqlite'),
    SQLALCHEMY_TRACK_MODIFICATIONS=False,
))
app.config.from_envvar('FLASKR_SETTINGS', silent=True)
app.config.from_object(__name__)

db = SQLAlchemy(app)
scheduler = BackgroundScheduler()
scheduler.start()
# Shut down the scheduler when exiting the app
atexit.register(lambda: scheduler.shutdown())

scheduler.add_job(
    func=disable_old_hosts,
    trigger=IntervalTrigger(minutes=1),
    id='clean_job',
    name='Clean inactive hosts',
    replace_existing=True
)


class Pong(db.Model):
    """
    Definition of a Pong.

    host: IP address of a pong device
    region:
        String that represent the geographic Datacenter or region location
        of the ponger. Example: MAD, Madrid, Spain, DC01.MADRID
    cluster:
        String that define the cluster name, this is usually the
        division name used within a DC. Example: CL10, CLUSTER1, etc
    rack:
        String, name of the rack where the ponger is located. Racks usually
        live within a cluster. Example: RS10AA, RACK01, etc.
    is_active:
        This boolean value represent if the ponger is alive (True) or no longer
        active (False).
    updated_datetime:
        Date value, represent the last time we had news from a ponger
    """
    host = db.Column(db.String(80), primary_key=True)
    region = db.Column(db.String(100))
    cluster = db.Column(db.String(100))
    rack = db.Column(db.String(100))
    is_active = db.Column(db.Boolean)
    updated_datetime = db.Column(db.DateTime)


def disable_old_hosts():
    """
    This method is called everytime the app runs. Checks if the pongers are
    contacting the application perodically (keepalive). If we didn't heard from
    a ponger for a while we disable that host.
    If the ponger is disabled its no loger served as a valid target to pingers
    """
    time_tresh = datetime.now() - timedelta(minutes=DEATH_TIMER)
    with app.app_context():
        servers = db.session.query(Pong).filter(
            Pong.is_active == True,
            Pong.updated_datetime < time_tresh
        )

        for ponger in servers.all():
            logger.info(
                'Disabling:{} last_updated:{}'.format(
                    ponger.host, ponger.updated_datetime
                )
            )
            ponger.is_active = False
            db.session.commit()
        pass


def serialize_server(obj):
    return {
        'host': obj.host,
        'rack': obj.rack,
        'cluster': obj.cluster,
        'region': obj.region,
        'is_active': obj.is_active,
        'updated_datetime': obj.updated_datetime
    }


def str_to_bool(s):
    if s == '1':
        return True
    else:
        return False


@app.cli.command('initdb')
def initdb_command():
    """Initializes the database."""
    db.create_all()
    logger.info('Database initialized')


@app.route('/')
def home():
    """
    Returns the list of active pongers to the caller (usually pingers):

    Example:

    OUTPUT:

    {
      "json_list": [
        {
          "cluster": "CLUSTER_1",
          "host": "10.142.0.4",
          "is_active": true,
          "rack": "RACK_1",
          "region": "REGION_1",
          "updated_datetime": "Sun, 20 Aug 2017 14:53:01 GMT"
        },
        {
          "cluster": "CLUSTER_2",
          "host": "10.142.0.2",
          "is_active": true,
          "rack": "RACK_1",
          "region": "REGION_1",
          "updated_datetime": "Sun, 20 Aug 2017 14:53:01 GMT"
        }
      ]
    }
    """
    logger.info('Home...')
    servers = db.session.query(Pong).filter_by(is_active=True)
    return jsonify(json_list=[serialize_server(ponger) for ponger in servers.all()])


@app.route('/servers/update', methods=['POST'])
def update_log():
    """
    Pongers calls this service constantly as a keepalive mechanism, and to
    "unregister" (set is_alive to False) when they are no longer alive.

    Every time a ponger calls this method the active state is updated
    (is_alive) and the updated_datetime field is set to the current time.
    """
    logger.info('update_log: A ponger is calling the update service...')
    response = {'action': 'update', 'sucess': False}

    try:
        ip_addr = request.remote_addr
        logger.info(
            'Ponger identified with IP {}: Updating status'.format(ip_addr)
        )
        exists = db.session.query(
            db.session.query(Pong).filter_by(host=ip_addr).exists()
        ).scalar()

        logger.debug('request:{}'.format(request.form))
        is_active = str_to_bool(request.form['is_active'])
        logger.debug('is_active:{}'.format(is_active))
        curr_date = datetime.now()

        if exists:
            column = db.session.query(Pong).filter_by(host=ip_addr).first()
            column.is_active = is_active
            column.updated_datetime = curr_date
            db.session.commit()

            response = {
                'action': 'update',
                'sucess': True,
                'host': ip_addr,
                'is_active': is_active,
                'rack': column.rack,
                'cluster': column.cluster,
                'region': column.region,
                'updated_datetime': curr_date
            }

    except Exception as e:
        logger.debug('Could not register the ponger status: {}'.format(e))

    return jsonify(response)


@app.route('/servers/create', methods=['POST'])
def create_log():
    """
        When a new ponger is activated, this method is called.

        This will record basic ponger characteristics like: ip address, region,
        cluster and rack. The info is sent to the db.
        """
    response = {'action': 'create', 'sucess': False}
    logger.info('create_log: called by a ponger')

    ponger_info = request.form
    ip_addr = request.remote_addr
    logger.info('create_log: {} Attempting to register'.format(ip_addr))

    if not {'region', 'cluster', 'rack'} <= set(ponger_info):
        logger.error(
            'create_log: {} missing geographic location info.'.format(ip_addr)
        )
        return jsonify(response)

    for key in ponger_info:
        logger.debug('{}: {}'.format(key, ponger_info[key]))

    region = request.form['region']
    cluster = request.form['cluster']
    rack = request.form['rack']

    exists = db.session.query(
        db.session.query(Pong).filter_by(host=ip_addr).exists()
    ).scalar()

    is_active = True
    curr_date = datetime.now()

    if exists:
        logger.info(
            "create_log: We already know about this ponger {}. Refreshing info".
            format(ip_addr)
        )
        try:
            column = db.session.query(Pong).filter_by(host=ip_addr).first()
            column.is_active = is_active
            column.updated_datetime = curr_date
            column.region = region
            column.cluster = cluster
            column.rack = rack
            db.session.commit()
        except Exception as e:
            logger.error(
                "create_log: could not update the ponger {} information: {}".
                format(ip_addr, e)
            )
            return jsonify(response)
    else:
        logger.info(
            "create_log: {} is a new ponger. Registering".format(ip_addr)
        )
        try:
            serv = Pong(
                host=ip_addr,
                is_active=is_active,
                updated_datetime=curr_date,
                region=region,
                cluster=cluster,
                rack=rack
            )
            db.session.add(serv)
            db.session.commit()
        except Exception as e:
            logger.error(
                "create_log: could not register the ponger {}: {}".
                format(ip_addr, e)
            )
            return jsonify(response)
            
    response = {
        'action': 'update',
        'sucess': True,
        'region': region,
        'cluster': cluster,
        'rack': rack,
        'host': ip_addr,
        'is_active': is_active,
        'updated_datetime': curr_date
    }

    return jsonify(response)


if __name__ == '__main__':
    app.run()
