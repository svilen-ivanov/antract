# antract

`antract` is an [OpenResty](http://openresty.org) set of scripts written in Lua to help you perform _simple_ zero downtime maintenance on the backend service. Its goal is to limit the impact to the user by holding incoming requests "in flight" while the backend service is taken down for maintenance and started back up again. The user sees a long request, and things carry right along. It is heavily based on the [37 Signal's `intermission` project](https://github.com/basecamp/intermission) with the following updates:
* if the client closes the connection during the maintenance window, the request to the backend is aborted. Thanks to @sirupsen for [pointing this up](https://github.com/basecamp/intermission/issues/5)
* the attempt to unblock the requests in the same order they came in is removed. The original implementation [suffers from some shortcomings](https://github.com/basecamp/intermission/issues/5). In my opinion, you can't maintain such contract in a web environment ([considering the example here](https://github.com/basecamp/intermission/issues/5#issuecomment-149573060)) if a client performs requests without waiting for the previous (potentially held in-flight) request to finish. In that case out-of-order execution could happen anytime, even during normal operation of the application

### Why

I run a low traffic service which occasionally serves file uploads which I don't want to interrupt when performing upgrades. A typical ["blue-green" deployments](https://martinfowler.com/bliki/BlueGreenDeployment.html) requires more effort and planning especially around applying database migrations.

### How to perform zero downtime maintenance on the backend service?
1. Enable `antract` by calling `/_antract/enable` endpoint.
    * existing requests (long requests, file uploads, etc.) will continue to be served by the backend service until they finish
    * new requests will be held in-flight until `antract` is disabled
2. Wait for all the requests to finish on the backend service. You can use monitoring metrics on your backend service to determine when it's safe to proceed with the maintenance. If your service supports graceful shutdown that waits for active connections to finish, you can skip this step
3. Shutdown the backend service and perform the maintenance
4. Start the backend service
5. Disable `antract` by calling `/_antract/disable` endpoint.
   * held in-flight requests will be unblocked and served by the backend service. Any canceled requests by the client will not reach the backend service
   * new requests will be served by the backend service as usual

Ideally, the time between steps 1 and 5 should be (much) less than `antract_max_time`, otherwise all queued requests will be automatically unblocked and served by the backend service as a fail-safe. If the service is not up, users will start seeing errors. 

## Gotchas
1. Requests can only be paused as long the device sitting in front of it will allow. If you have [haproxy](https://www.haproxy.org/) deployed in front of your OpenResty instance, make sure to check your `timeout` values. Otherwise, `haproxy` could abort the connection earlier than the actual client (browser) while `antract` keeps requests paused
2. Beware of [thundering herd](https://en.wikipedia.org/wiki/Thundering_herd_problem) problem. All queued up request will be unblocked immediately (with some jitter) to the backend once `antract` is disabled. This may overload the backend because it will receive many concurrent connections for a brief period of time (all held requests + perhaps new ones). Consider setting appropriate `max_conns` on your `server` directive in the `upstream` section. Since this project is aimed at rather small deployments, it is out of scope of `antract`. If this becomes a problem in your project, you should consider ["blue-green" deployments](https://martinfowler.com/bliki/BlueGreenDeployment.html) and perform changes incrementally, with backward compatibility.
 
## Other Approaches Considered

The project was inspired from [this post](https://til.simonwillison.net/caddy/pause-retry-traffic) by Simon Willison. I tried the approach with Caddy, but I couldn't gracefully halt the new incoming connections. More over, if queued request was `POST`, Caddy threw an error `http: invalid Read on closed Body` when the service was resumed and the client receives an error after being paused for some time.

I also tried haproxy as desribed in [this](https://serverfault.com/a/450983) and [this](https://serverfault.com/q/954694) posts but my haproxy was crashing when I attempted to set `maxconn` from `0` to non-zero to resume the service:
```
# queue incoming requests
echo "set maxconn frontend my_frontend 0" | socat stdio tcp4-connect:127.0.0.1:8080
# the request start hanging as expectd
# ... perform maintenance ...
# restore incoming requests
echo "set maxconn frontend my_frontend 1000" | socat stdio tcp4-connect:127.0.0.1:8080
# HAProxy crashes :(
```


## Trying it Out (Local)

1. Start the `antract` and a demo service:
   ```shell
   # Podman users:
   # export DOCKER_HOST="unix:$XDG_RUNTIME_DIR/podman/podman.sock"
   docker-compose up 
   ```
2. Hit [http://localhost:8082](http://localhost:8082). You should see demo service response:
   ```
   $ curl -D - http://localhost:8082
   HTTP/1.1 200 OK
   Server: openresty/1.21.4.3
   Date: Tue, 14 Nov 2023 11:16:38 GMT
   Content-Type: text/plain
   Content-Length: 141
   Connection: keep-alive
   Expires: Tue, 14 Nov 2023 11:16:37 GMT
   Cache-Control: no-cache
   
   Server address: 10.89.1.99:80
   Server name: 4c19d53eb531
   Date: 14/Nov/2023:11:16:38 +0000
   URI: /
   Request ID: 1b806d246800f935fc294109ce8ef3b5
   ```
3. Enable `antract`:
   ```
   $ curl -D - http://localhost:8082/_antract/enable
   HTTP/1.1 200 OK
   Server: openresty/1.21.4.3
   Date: Tue, 14 Nov 2023 11:18:08 GMT
   Content-Type: application/octet-stream
   Transfer-Encoding: chunked
   Connection: keep-alive
   
   Pause is enabled.
   ```
4. Check status:
   ```
   $ curl -D - http://localhost:8082/_antract/status
   HTTP/1.1 200 OK
   Server: openresty/1.21.4.3
   Date: Tue, 14 Nov 2023 11:19:04 GMT
   Content-Type: application/octet-stream
   Transfer-Encoding: chunked
   Connection: keep-alive
   
   Pause is enabled, 0 requests are currently paused. Free space in pausedreqs: 118784b
   ```
5. Hit [http://localhost:8082](http://localhost:8082) again. You should see the request is paused:
   ```
   $ curl -vv -D - http://localhost:8082
   *   Trying 127.0.0.1:8082...
   * Connected to localhost (127.0.0.1) port 8082 (#0)
   > GET / HTTP/1.1
   > Host: localhost:8082
   > User-Agent: curl/7.81.0
   > Accept: */*
   >
6. Hit status again, you should see the hanging request:
   ```
   curl -D - http://localhost:8082/_antract/status
   HTTP/1.1 200 OK
   Server: openresty/1.21.4.3
   Date: Tue, 14 Nov 2023 11:20:52 GMT
   Content-Type: application/octet-stream
   Transfer-Encoding: chunked
   Connection: keep-alive
   
   Pause is enabled, 1 requests are currently paused. Free space in pausedreqs: 118784b
   ```
7. Disable `antract`:
   ```
   $ curl -D - http://localhost:8082/_antract/disable
   HTTP/1.1 200 OK
   Server: openresty/1.21.4.3
   Date: Tue, 14 Nov 2023 11:21:37 GMT
   Content-Type: application/octet-stream
   Transfer-Encoding: chunked
   Connection: keep-alive
   
   Pause is disabled. 1 requests were held in-flight.
   ```
8. Your request from step #5 should be unblocked:
   ```
   $ curl -vv -D - http://localhost:8082
   *   Trying 127.0.0.1:8082...
   * Connected to localhost (127.0.0.1) port 8082 (#0)
   > GET / HTTP/1.1
   > Host: localhost:8082
   > User-Agent: curl/7.81.0
   > Accept: */*
   >
   * Mark bundle as not supporting multiuse
     < HTTP/1.1 200 OK
     HTTP/1.1 200 OK
     < Server: openresty/1.21.4.3
     Server: openresty/1.21.4.3
     < Date: Tue, 14 Nov 2023 11:21:38 GMT
     Date: Tue, 14 Nov 2023 11:21:38 GMT
     < Content-Type: text/plain
     Content-Type: text/plain
     < Content-Length: 141
     Content-Length: 141
     < Connection: keep-alive
     Connection: keep-alive
     < Expires: Tue, 14 Nov 2023 11:21:37 GMT
     Expires: Tue, 14 Nov 2023 11:21:37 GMT
     < Cache-Control: no-cache
     Cache-Control: no-cache
   
   <
   Server address: 10.89.1.99:80
   Server name: 4c19d53eb531
   Date: 14/Nov/2023:11:21:38 +0000
   URI: /
   Request ID: 81efab8bb6afa68f214151b1116d6e0a
   * Connection #0 to host localhost left intact
   ```

## Advanced Usage

### Many Virtual Hosts

If you have many virtual hosts running on one nginx instance, you most likely don't want to pause all of them.  You can scope the pause to a virtual server by setting $app_name in the server directive of the virtual host:

    server {
      # Stick the app name in an nginx variable for use with antract.
      # Since we want it set for all of the app requests, set it at the 
      # server level.
      set $app_name <%= @app_name %>; 

      # ... rest of config ...
     }

### Customizing Antract's Behavior

Please check [`sample-nginx.conf`](sample-nginx.conf) for more details.

##### What if your health check isn't at `/up`? 

Simply override the `$antract_health_check_path` in the nginx config.  

##### What if you want a longer max pause time?  

Override `$antract_max_time` in the nginx config.  

#### What if there's an external service like Pingdom and you always want their checks to succeed?

Override `$antract_privileged_user_agent` in the nginx config.

## What does `antract` mean?

Kudos to original authors for the great `intermission` name. **Antract** is the phonetical spelling of the bulgarian word for "intermission" (which comes from the French `entracte` with the same meaning).

## Getting help with antract
The fastest way to get help is to send an email to [svilen.ivanov@gmail.com](svilen.ivanov@gmail.com). 
Github issues and pull requests are checked regularly.

## Contributing
Pull requests with passing tests (there are no tests!) are welcomed and appreciated.

## Contributors

Original authors of [`intermission`](https://github.com/basecamp/intermission)
 * [Taylor Weibley](https://github.com/tweibley)
 * [Matthew Kent](https://github.com/mdkent)
 * [Nathan Anderson](https://github.com/anoldguy)

`Antract` contributors:
 * [Svilen Ivanov](https://www.linkedin.com/in/svilenivanov/)

# License
```
Copyright (c) 2012 37signals (37signals.com)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
