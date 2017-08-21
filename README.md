# OpenNetNorad

NetNorad is Facebook’s system for network packet loss measurement using active probing [1]. It follows a simple principle of specific hosts acting as pingers with pongers on all servers. It stores the response in a time series DB, provides analytics of the data and ultimately a source for alarms for operations.

Using OpenSource software, including UdpPinger (a high performance UDP packet generation, reflection and collection library)    [2], we can build a solution similar to Facebook’s NetNorad by leveraging InfluxDB, flask, Python and a few bash scripts.

These instructions will create a sample system to manage Uping and Upong instances that we can use to have a solution to measure / graph network latency and loss on Linux

[1] NANOG 66 NetNorad presentation: https://www.youtube.com/watch?v=N0lZrJVdI9A

[2] https://github.com/facebook/UdpPinger

----------

These instructions are for Debian stable (should work for other debian based distros)


Install pong_logger webservice
-------------

- Install Nginx web server and Apache utils (to generate http-auth config files easily)

    `sudo apt update && sudo apt install -y nginx apache2-utils`

- Generate a http-auth config file with the user 'pong_user'. This authentication definition will be used by the pong agents to send information to the controller (Example: upong register operation).

    ```
    sudo htpasswd -c /etc/nginx/.htpasswd pong_user
    New password: 
    Re-type new password: 
    Adding password for user pong_user
    ```
    
- Remove default Nginx configuration

    `sudo rm /etc/nginx/sites-enabled/default`
    
- Clone the pong_logger project
    
    `cd /var/www/ && git clone https://github.com/drodrigueza/OpenNetnorad`

- Copy the nginx config file of the web system to '/etc/nginx/sites-enabled' and **edit server_name** to be the IP address of your server/instance or FQDN
    
    `sudo cp OpenNetNorad/scripts/nginx_pong_logger.conf /etc/nginx/sites-enabled/`
    
    `vim /etc/nginx/sites-enabled/nginx_pong_logger.conf`
    
    Example:
    
    ```
    server {
    listen 5000;
    server_name 192.168.1.1;
    location / {
        include uwsgi_params;
        uwsgi_pass unix:///var/www/OpenNetNorad/pong_logger/pong_logger.sock;
        }
    }
    ```
    
    - Optionally you can also set a diferent listening port for nginx (5000 by default)

- Install pip for python3:

    `sudo apt install python3-pip`

- Now you need to install the modules that we use on the controller code to handle the pingers/pongers and to make everything run.

    `sudo apt install python3-flask python3-flask-sqlalchemy uwsgi uwsgi-plugin-python3`

    `sudo pip3 install apscheduler`
    
- We provide a base "empty" sqlite DB that is used by the framework to register pinger and pongers activity. You need to copy the needed files and set permissions accordingly.
    
    `sudo cp OpenNetNorad/pong_logger/app.sqlite.base OpenNetNorad/pong_logger/app.sqlite`
    
    `sudo chmod 755 OpenNetNorad/pong_logger/app.sqlite && sudo chown www-data: OpenNetNorad/pong_logger/app.sqlite`
    
    `sudo chown -R www-data: /var/www/OpenNetNorad/pong_logger/`

- Prepare the uwsgi service

    `sudo cp OpenNetNorad/scripts/pong_logger.service /lib/systemd/system/`
    
    `sudo systemctl enable pong_logger`
    
    `sudo systemctl start pong_logger`
    
- Prepare rsyslog log configuration file. In this step we basically create a rsyslog configuration file, that is going to handle the log information from our controller, this log could be useful for troubleshooting or detecting dead pingers.
    
    `echo ':syslogtag, isequal, "pong_logger:"     /var/log/pong_logger.log' | sudo tee -a /etc/rsyslog.d/pong_logger.conf`
    
    `sudo systemctl restart rsyslog`
    
- Restart Nginx

    `sudo systemctl restart nginx`
    

Install Influxdb and Chronograf
-------------

- Generate a http-auth config file with the user 'chronograf_user'

    ```
    htpasswd /etc/nginx/.htpasswd chronograf_user
    New password: 
    Re-type new password: 
    Adding password for user chronograf_user
    ```

- Install the TICK stack: https://docs.influxdata.com/chronograf/v1.3/introduction/getting-started/

- Configure Telegraf to listen HTTP messages, append the following lines at the end of the file `/etc/telegraf/telegraf.conf`
    ```
      [[inputs.http_listener]]
      ## Address and port to host HTTP listener on
      service_address = ":8186"
      ## maximum duration before timing out read of the request
      read_timeout = "10s"
      ## maximum duration before timing out write of the response
      write_timeout = "10s"
      ## Maximum allowed http request body size in bytes.
      ## 0 means to use the default of 536,870,912 bytes (500 mebibytes)
      max_body_size = 0
      ## Maximum line size allowed to be sent in bytes.
      ## 0 means to use the default of 65536 bytes (64 kibibytes)
      max_line_size = 0
    ```

- Copy the nginx config file of the web system (controller) to '/etc/nginx/sites-enabled' 
    
    `sudo cp OpenNetNorad/scripts/nginx_chronograf.conf /etc/nginx/sites-enabled/`
    
- Setup the Chronograf DB: This involves copying a "basic" empty DB with the needed structure to hold the information sent by the pingers, and setting up the correct permissions.

    `sudo systemctl stop chronograf`
    
    `sudo cp OpenNetNorad/chronograf/chronograf-v1.db /var/lib/chronograf/chronograf-v1.db`
    
    `sudo chown chronograf: /var/lib/chronograf/chronograf-v1.db`
    
    `sudo chmod 600 /var/lib/chronograf/chronograf-v1.db`
    

- Secure chronograf, edit to allow listen on 127.0.0.1 only

    - `sudo vim /lib/systemd/system/chronograf.service`
        
        - *ExecStart=/usr/bin/chronograf --host 127.0.0.1 --port 8888 -b /var/lib/chronograf/chronograf-v1.db -c /usr/share/chronograf/canned*
    

- Restart Services
    
    `sudo systemctl restart telegraf`
    
    `sudo systemctl restart chronograf`
    
    `sudo systemctl restart nginx`
    

- Open chronograf on http://YOUR_IP_OR_FQDN:8080

Pre-install in both roles
-------------

Things to install before anything:

- `sudo apt update && sudo apt -y install wget git python3-dev python-dev unzip`
- Download https://github.com/drodrigueza/OpenNetNorad/tree/master/debian the deb files for your Debian version.
- Install udping packages:
    - dpkg -i libfolly57.0_57.0-1_amd64.deb libfolly-dev_57.0-1_amd64.deb thrift_1-1_amd64.deb udppinger_1-1_amd64.deb 
    - apt -f install


Install Upongd service
-------------

- Copy and **edit** the service files 

    `sudo cp OpenNetNorad/scripts/upongd.service /lib/systemd/system/`
    
- *You must define the parameters of the **upongd.service** script*: Configure the REGION, CLUSTER, and RACK depending on your network hierarchy and geographical location. If you dont have a network that suits this labels, we recommend you to use only the REGION label, and then define the cluster and rack as "DEFAULT". You also need to define the MASTER server: This should be the IP address or FQDN of your controller.
    
    `sudo vim /lib/systemd/system/upongd.service`
    
    Example:
    
    ```
    [Unit]
    Description=Upongd daemon to manage upong
    After=network.target
    [Service]
    ExecStart=/usr/local/bin/upong
    PIDFile=/var/run/upongd.pid
    ExecStartPre=-/usr/bin/wget -O - --post-data=region=MAD1&cluster=CS10&rack=R2 http://192.168.1.1:5000/servers/create
    ExecStopPost=-/usr/bin/wget -O - --post-data=is_active=0 http://192.168.1.1:5000/servers/update
    Type=simple
    User=root
    Group=root
    [Install]
    WantedBy=multi-user.target
    ```
    
    `sudo systemctl enable upongd`
    
    `sudo systemctl start upongd`
    
- Install the upong report script (Keepalive logic). You must **edit** the *report_upongd_systemd.sh* file and define the address/FQDN of the controller/logger device. 

    `sudo mkdir /etc/OpenNetNorad/`

    `sudo cp OpenNetNorad/scripts/report_upongd_systemd.sh /etc/OpenNetNorad/`
    
    `sudo vim /etc/OpenNetNorad/report_upongd_systemd.sh`
    
    Example:
    
    ```
    LOG_SERVER="192.168.1.1"
    REGISTER_RUNNING="/usr/bin/wget -O - --post-data=is_active=1 http://$LOG_SERVER:5000/servers/update"
    REGISTER_STOPPED="/usr/bin/wget -O - --post-data=is_active=0 http://$LOG_SERVER:5000/servers/update"
    if [ -n "systemctl is-active sshd >/dev/null 2>&1" ]; then
        REG_RES=`$REGISTER_RUNNING`
    else
        REG_RES=`$REGISTER_STOPPED`
    fi
    ```
    
    `echo '*/1 *   * * *   root    /etc/OpenNetNorad/report_upongd_systemd.sh' | sudo tee -a /etc/crontab`
 
    
Install Upinger scripts
-------------

- `sudo apt update && sudo apt install wget`

- Install the Uping report script. And configure the crontab with the needed parameters: Following the same logic as the ponger you need to define the geografic position of the pinger (rack, cluster and region), and the IP address/FQDN of the controller/logger server.

    `sudo cp OpenNetNorad/scripts/udppinger_collect_telegraf.sh /etc/OpenNetNorad/`
    
    `echo '*/1 *   * * *   root    /etc/OpenNetNorad/udppinger_collect_telegraf.sh -m IP_OF_THE_WEB_SERVER -l IP_OF_THE_TELEGRAF_LOG_SERVER -s THE_IP_OF_THIS_MACHINE -c "PINGER_CLUSTER" -r "PINGER_RACK" -e "PINGER_REGION"' | sudo tee -a /etc/crontab`
    
    Example:
    
    `echo '*/1 *   * * *   root    /etc/OpenNetNorad/udppinger_collect_telegraf.sh -m 192.168.1.1 -l 192.168.1.1 -s 192.168.1.100 -c "CS5" -r "R10" -e "DUB3"' | sudo tee -a /etc/crontab`
 
