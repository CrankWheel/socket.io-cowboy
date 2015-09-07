Websocket example
=================

This is a copy of Cowboy's websocket example, modified to act as a stress test
on Cowboy doing a broadcast-to-all-connections type of "chat server".

To try this example, you need GNU `make` and `git` in your PATH.

To build the example, run the following command:

``` bash
$ make
```

To start the release in the foreground:

``` bash
$ ./_rel/websocket_example/bin/websocket_example console
```

Then point your browser at [http://localhost:8080](http://localhost:8080).
