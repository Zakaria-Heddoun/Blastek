// GraphQL subscriptions over the Phoenix socket (E6-T10 / F0.10, using E2-T4).
//
// The server side has been ready since E2; this is the client that was never
// written. It exists for one thing so far — telling a dashboard that a booking
// just landed — but the transport is the general one, so the walk-in queue
// (F1.9) will not need a second.
//
// ## Why not a GraphQL client library
//
// Because the whole surface is "open a socket, join `__absinthe__:control`,
// send a `doc`, receive events". The libraries that wrap this bring a cache, a
// normalizer and a build step, none of which this app uses for its queries
// either — `gql()` is thirty lines of `fetch`. Consistency is worth more here
// than the abstraction.
import { Socket } from 'phoenix';

type Handler<T> = (payload: T) => void;

interface Subscription {
  /** Stops delivery and, when it is the last one, closes the socket. */
  unsubscribe: () => void;
}

let socket: Socket | null = null;
let control: ReturnType<Socket['channel']> | null = null;
let refCount = 0;

// Server-assigned subscription id → handler. Absinthe publishes each
// subscription on a topic named after that id.
const handlers = new Map<string, Handler<unknown>>();

function connect(): ReturnType<Socket['channel']> {
  if (control) return control;

  const token = localStorage.getItem('blastek-token');
  const venue = localStorage.getItem('blastek-venue');

  // The socket authenticates once, at connect: it is long-lived, so the params
  // here are the only point at which the caller is identified.
  socket = new Socket('/socket', {
    params: { token: token ?? '', venue: venue ?? '' },
  });

  socket.connect();

  // Every frame, whatever its topic. Absinthe publishes subscription data on a
  // topic named after the subscription id, and that topic is *not* a joinable
  // channel — joining it crashes on the server. `channel.on` therefore never
  // fires and the socket looks perfectly healthy while nothing arrives, which
  // is the most expensive way for this to fail.
  socket.onMessage((message: object) => {
    const { topic, event, payload } = message as {
      topic?: string;
      event?: string;
      payload?: { result?: { data?: unknown } };
    };

    if (event !== 'subscription:data' || !topic) return;
    const handler = handlers.get(topic);
    if (handler && payload?.result?.data) handler(payload.result.data);
  });

  // `doc` messages go out on the control channel; the data comes back above.
  control = socket.channel('__absinthe__:control', {});
  control.join();
  return control;
}

function disconnect() {
  control?.leave();
  socket?.disconnect();
  control = null;
  socket = null;
  handlers.clear();
}

/**
 * Subscribes to a GraphQL subscription document.
 *
 * Resolves once the server has accepted it. A failure to subscribe is not
 * thrown: live updates are an enhancement over a page that already works by
 * loading, and a dashboard that refuses to render because a websocket is
 * blocked would be worse than one that quietly does not update itself.
 */
export function subscribe<T>(doc: string, onData: Handler<T>): Promise<Subscription> {
  return new Promise((resolve) => {
    let id: string | null = null;
    let cancelled = false;
    refCount += 1;

    const done = () => {
      if (cancelled) return;
      cancelled = true;
      if (id) {
        handlers.delete(id);
        control?.push('unsubscribe', { subscriptionId: id });
      }
      refCount -= 1;
      if (refCount <= 0) disconnect();
    };

    try {
      connect()
        .push('doc', { query: doc })
        .receive('ok', (reply: { subscriptionId?: string }) => {
          if (!cancelled && reply.subscriptionId) {
            id = reply.subscriptionId;
            handlers.set(id, onData as Handler<unknown>);
          }

          resolve({ unsubscribe: done });
        })
        .receive('error', () => resolve({ unsubscribe: done }))
        .receive('timeout', () => resolve({ unsubscribe: done }));
    } catch {
      resolve({ unsubscribe: done });
    }
  });
}
