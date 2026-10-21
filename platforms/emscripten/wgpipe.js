/*
 * wgpipe.js: sockets between the client and the server over MessagePorts
 *
 * The client runs on the page and the server in a Web Worker, so instead of
 * TCP they talk over MessagePorts, one per connection. This replaces the
 * WebSocket backend of Emscripten's SOCKFS. The page provides
 * Module.wgPipe = { connect(port) } on the client side, returning a
 * MessagePort (or null when nothing listens), and the worker provides
 * Module.wgPipe = { listen(port, onConnection) } on the server side.
 * A message is an ArrayBuffer of stream bytes, or null when the other end
 * closes.
 *
 * This file is licensed under Gnu General Public License version 2 or later.
 */

addToLibrary({
  $WGPIPE__deps: ['$SOCKFS', '$FS'],
  $WGPIPE__postset: 'WGPIPE.install();',
  $WGPIPE: {
    waiter: null,
    install() {
      SOCKFS.websocket_sock_ops = WGPIPE.ops;
    },
    // Wakes a wg_pipe_wait() in progress
    wake() {
      var waiter = WGPIPE.waiter;

      WGPIPE.waiter = null;
      waiter?.();
    },
    attach(sock, port) {
      sock.port = port;
      sock.closed = false;
      port.onmessage = (e) => {
        if (e.data === null) {
          sock.closed = true;
          port.close();
        } else {
          sock.recv_queue.push(new Uint8Array(e.data));
        }
        WGPIPE.wake();
      };
    },
    ops: {
      poll(sock) {
        if (sock.server) {
          return sock.pending.length ? ({{{ cDefs.POLLRDNORM }}} | {{{ cDefs.POLLIN }}}) : 0;
        }
        if (!sock.port) {
          return {{{ cDefs.POLLOUT }}};
        }

        var mask = 0;

        if (sock.recv_queue.length || sock.closed) {
          mask |= ({{{ cDefs.POLLRDNORM }}} | {{{ cDefs.POLLIN }}});
        }
        if (sock.closed) {
          mask |= {{{ cDefs.POLLHUP }}};
        } else {
          mask |= {{{ cDefs.POLLOUT }}};
        }

        return mask;
      },
      ioctl(sock, request, arg) {
        if (request == {{{ cDefs.FIONREAD }}}) {
          var bytes = sock.recv_queue.length ? sock.recv_queue[0].length : 0;

          {{{ makeSetValue('arg', '0', 'bytes', 'i32') }}};
          return 0;
        }
        return {{{ cDefs.EINVAL }}};
      },
      close(sock) {
        if (sock.server) {
          Module['wgPipe']?.unlisten?.(sock.sport);
          sock.server = null;
        }
        if (sock.port && !sock.closed) {
          sock.port.postMessage(null);
          sock.port.close();
        }
        sock.closed = true;
        return 0;
      },
      bind(sock, addr, port) {
        if (typeof sock.saddr != 'undefined' || typeof sock.sport != 'undefined') {
          throw new FS.ErrnoError({{{ cDefs.EINVAL }}});
        }
        sock.saddr = addr;
        sock.sport = port;
      },
      connect(sock, addr, port) {
        if (sock.server) {
          throw new FS.ErrnoError({{{ cDefs.EOPNOTSUPP }}});
        }
        if (sock.port) {
          throw new FS.ErrnoError({{{ cDefs.EISCONN }}});
        }

        var mp = Module['wgPipe']?.connect?.(port);

        if (!mp) {
          throw new FS.ErrnoError({{{ cDefs.ECONNREFUSED }}});
        }
        WGPIPE.attach(sock, mp);
        sock.daddr = addr;
        sock.dport = port;
      },
      listen(sock, backlog) {
        var pipe = Module['wgPipe'];

        if (!pipe?.listen) {
          throw new FS.ErrnoError({{{ cDefs.EOPNOTSUPP }}});
        }
        if (sock.server) {
          throw new FS.ErrnoError({{{ cDefs.EINVAL }}});
        }
        sock.server = true;
        pipe.listen(sock.sport, (mp) => {
          var newsock = SOCKFS.createSocket(sock.family, sock.type, sock.protocol);

          WGPIPE.attach(newsock, mp);
          newsock.daddr = '127.0.0.1';
          newsock.dport = 0;
          sock.pending.push(newsock);
          WGPIPE.wake();
        });
      },
      accept(listensock) {
        if (!listensock.server || !listensock.pending.length) {
          throw new FS.ErrnoError({{{ cDefs.EINVAL }}});
        }

        var newsock = listensock.pending.shift();

        newsock.stream.flags = listensock.stream.flags;
        return newsock;
      },
      getname(sock, peer) {
        if (peer) {
          if (sock.daddr === undefined) {
            throw new FS.ErrnoError({{{ cDefs.ENOTCONN }}});
          }
          return { addr: sock.daddr, port: sock.dport };
        }
        return { addr: sock.saddr || '127.0.0.1', port: sock.sport || 0 };
      },
      sendmsg(sock, buffer, offset, length, addr, port) {
        if (!sock.port) {
          throw new FS.ErrnoError({{{ cDefs.ENOTCONN }}});
        }
        if (sock.closed) {
          throw new FS.ErrnoError({{{ cDefs.EPIPE }}});
        }

        var data = new Uint8Array(length);

        data.set(buffer.subarray(offset, offset + length));
        sock.port.postMessage(data.buffer, [data.buffer]);
        return length;
      },
      recvmsg(sock, length) {
        if (sock.server) {
          throw new FS.ErrnoError({{{ cDefs.ENOTCONN }}});
        }

        var queued = sock.recv_queue.shift();

        if (!queued) {
          if (!sock.port) {
            throw new FS.ErrnoError({{{ cDefs.ENOTCONN }}});
          }
          if (sock.closed) {
            return null;
          }
          throw new FS.ErrnoError({{{ cDefs.EAGAIN }}});
        }
        if (queued.length > length) {
          sock.recv_queue.unshift(queued.subarray(length));
          queued = queued.subarray(0, length);
        }

        return { buffer: queued, addr: sock.daddr, port: sock.dport };
      }
    }
  },

  // Sleeps for up to ms milliseconds, or until a pipe has news
  wg_pipe_wait__deps: ['$WGPIPE'],
  wg_pipe_wait__async: true,
  wg_pipe_wait: (ms) => Asyncify.handleSleep((wakeUp) => {
    var timer = setTimeout(() => WGPIPE.wake(), ms);

    WGPIPE.waiter = () => {
      clearTimeout(timer);
      wakeUp();
    };
  }),

  // Sleeps until the browser draws the next frame, and while the page
  // holds the game (Module.wgHeld)
  wg_next_frame__async: true,
  wg_next_frame: () => Asyncify.handleSleep((wakeUp) => {
    var tick = () => {
      if (Module['wgHeld']) {
        setTimeout(tick, 100);
      } else {
        wakeUp();
      }
    };

    if (typeof requestAnimationFrame == 'function' && document.visibilityState != 'hidden') {
      requestAnimationFrame(tick);
    } else {
      setTimeout(tick, 50);
    }
  }),
});
