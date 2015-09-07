#!/usr/bin/env python

# Requires: sudo pip install websocket-client

import websocket
import sys
import thread
import time

sending = 0
expecting = 0
received = 0
start_time = 0

def on_message(ws, message):
    global expecting
    global received
    received += 1
    if received >= expecting:
        end_time = int(round(time.time() * 1000))
        print("Received message #%d in %d ms" % (received, end_time - start_time))
        sys.exit(0)

def on_error(ws, error):
    print(error)

def on_close(ws):
    print("### closed ###")

def on_open(ws):
    time.sleep(5)
    def run(*args):
        print("Sending %d messages" % sending)
        global start_time
        start_time = int(round(time.time() * 1000))
        for i in range(sending):
            ws.send("PING")
        print("thread terminating...")
    thread.start_new_thread(run, ())

if __name__ == "__main__":
    global sending
    global expecting
    sending = int(sys.argv[1])
    expecting = int(sys.argv[2])
    print "Sending %d, expecting %d" % (sending, expecting)
    websocket.enableTrace(True)
    ws = websocket.WebSocketApp("ws://localhost:8080/websocket",
                                on_message = on_message,
                                on_error = on_error,
                                on_close = on_close)
    ws.on_open = on_open

    ws.run_forever()
