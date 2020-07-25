module libfuture.common;

import core.thread : Fiber;
import core.sync.event : Event;
import core.time : Duration;

///
auto await(T : Fiber)(auto ref T fiber)
{
	while (fiber.state != Fiber.State.TERM)
	{
		fiber.call();
		if (fiber.state != Fiber.State.TERM && Fiber.getThis())
		{
			Fiber.yield();
		}
	}

	static if (__traits(compiles, { return fiber.result; }))
	{
		return fiber.result;
	}
}

@("await: Works as a force wait if not in Fiber")
unittest
{
    int n = 0;
    auto t = new Fiber({
        n = 1;
        Fiber.yield();
        n = 2;
        Fiber.yield();
        n = 3;
    });

    assert(n == 0);
    t.await; // force wait
    assert(n == 3);
}

@("await: 内部のFiber.yield()を直接書いたときと同じ動作(yield 1回)")
unittest
{
    int n = 1;
    auto inner = new Fiber({
        n += 1;
        Fiber.yield();
        n += 1;
    });
    auto outer = new Fiber({
        n *= 2;
        inner.await;
        n *= 2;
    });
    assert(n == 1);
    outer.call(); // *= 2; += 1; before Fiber.yield()
    assert(n == 3);
    outer.call(); // += 1; *= 2; after Fiber.yield()
    assert(n == 8);
    assert(inner.state == Fiber.State.TERM);
    assert(outer.state == Fiber.State.TERM);
}

@("await: 内部のFiber.yield()を直接書いたときと同じ動作(yield 2回)")
unittest
{
    int n = 1;
    auto inner = new Fiber({
        n += 1;
        Fiber.yield();
        n += 1;
        Fiber.yield();
        n += 1;
    });
    auto outer = new Fiber({
        n *= 2;
        inner.await;
        n *= 2;
    });
    assert(n == 1);
    outer.call(); // *= 2; += 1; before Fiber.yield()
    assert(n == 3);
    outer.call(); // += 1; between Fiber.yield()
    assert(n == 4);
    outer.call(); // += 1; *= 2; after Fiber.yield()
    assert(n == 10);
    assert(inner.state == Fiber.State.TERM);
    assert(outer.state == Fiber.State.TERM);
}

///
class Future(T) : Fiber
{
    enum ResolveState
    {
        Running,
        Fulfilled,
        Rejected
    }

	private Event event;
	private ResolveState resolveState = ResolveState.Running;
    static if (!is(T == void))
    {
        private T value;
    }
    private Throwable throwable;

    static if (is(T == void))
    {
        this(void delegate() delegate(void delegate(), void delegate(Throwable)) factory)
        {
            event.initialize(true, false);
            super({
                factory(&setResult, &setReject)();
                yieldImpl();
            });
        }
        
        this(void delegate() delegate(void delegate()) factory)
        {
            event.initialize(true, false);
            super({
                factory(&setResult)();
                yieldImpl();
            });
        }

        this(void delegate() action)
        {
            event.initialize(true, false);
            super({
                action();
                setResult();
            });
        }

        this(void delegate(void delegate() resolve) dg)
        {
            event.initialize(true, false);
            super({
                dg(&setResult);
                yieldImpl();
            });
        }
    }
    else
    {
        this(void delegate() delegate(void delegate(T), void delegate(Throwable)) factory)
        {
            event.initialize(true, false);
            super({
                factory(&setResult, &setReject)();
                yieldImpl();
            });
        }

        this(void delegate() delegate(void delegate(T)) factory)
        {
            event.initialize(true, false);
            super({
                factory(&setResult)();
                yieldImpl();
            });
        }

        this(T delegate() action)
        {
            event.initialize(true, false);
            super({
                setResult(action());
            });
        }

        this(void delegate(void delegate(T) resolve) dg)
        {
            event.initialize(true, false);
            super({
                dg(&setResult);
                yieldImpl();
            });
        }
    }

    static if (!is(T == void))
    {
        T result()
        {
            if (this.state != Fiber.State.TERM)
            {
                call();
                event.wait();
            }
            return value;
        }
    }

    private void yieldImpl()
    {
        while (!event.wait(Duration.zero))
        {
            if (resolveState == ResolveState.Fulfilled)
                Fiber.yield();
            else
                Fiber.yieldAndThrow(this.throwable);
        }
    }

    static if (is(T == void))
    {
        private void setResult()
        {
            resolveState = ResolveState.Fulfilled;
            event.set();
        }
    }
    else
    {
        private void setResult(T obj)
        {
            value = obj;
            resolveState = ResolveState.Fulfilled;
            event.set();
        }
    }

    private void setReject(Throwable t)
    {
        this.throwable = t;
        resolveState = ResolveState.Rejected;
        event.set();
    }
}

@("Future: Just like regular Fiber")
unittest
{
    int n = 0;
    auto t1 = new Future!int(resolve => {
        n = 1;
        resolve(10);
    });
    assert(n == 0);
    t1.call();
    assert(n == 1);
    assert(t1.state == Fiber.State.TERM);
    assert(t1.result == 10);
}

@("Future: Nested")
unittest
{
    auto inner = new Future!int(resolve => {
        resolve(10);
    });
    auto outer = new Future!int(resolve => {
        const x = inner.await;
        resolve(x * 2);
    });

    const y = outer.await;
    assert(y == 20);
}

@("Future: try-catch can handle internal Fiber exceptions")
unittest
{
    auto t = new Fiber({
        throw new Exception("");
    });

    const x = new Future!int(resolve => {
        try
        {
            t.await; // throw and reject
            resolve(1);
        }
        catch (Exception ex)
        {
            resolve(2);
        }
    }).await;
    assert(x == 2);
}

@("Future.result: Works as a force wait")
unittest
{
    auto t = new Future!string(resolve => {
        resolve("FUTURE");
    });
    string text = t.result;
    assert(text == "FUTURE");
}

@("Future: async resolve")
unittest
{
    auto t = new Future!string(resolve => {
        import std.parallelism : taskPool, task;
        import core.thread : Thread;
        import core.time : msecs;
        taskPool.put(task({
            Thread.sleep(20.msecs);
            resolve("OK");
        }));
    });

    const string text = t.await;
    assert(text == "OK");
}

@("Future: async reject")
unittest
{
    auto t = new Future!string((resolve, reject) => {
        import std.parallelism : taskPool, task;
        import core.thread : Thread;
        import core.time : msecs;
        taskPool.put(task({
            Thread.sleep(20.msecs);
            reject(new Exception("REJECT"));
        }));
    });

    try
    {
        t.await;
    }
    catch (Exception ex)
    {
        assert(ex.msg == "REJECT");
        return;
    }
    assert(false);
}

@("Future: return value")
unittest
{
    auto tenMsecs = new Future!int(resolve => {
        import std.parallelism : taskPool, task;
        import core.thread : Thread;
        import core.time : msecs;
        taskPool.put(task({
            Thread.sleep(10.msecs);
            resolve(10);
        }));
    });

    const t = new Future!int({
        return tenMsecs.await + 10;
    }).await;
    assert(t == 20);
}

struct FutureFactory
{
    @disable this();

    static Future!T startNew(T)(T delegate() action)
    {
        Future!T t;
        t = new Future!T((resolve, reject) => {
            import core.thread : Thread;
            new Thread({
                try
                {
                    static if (is(T == void))
                    {
                        action();
                        resolve();
                    }
                    else
                    {
                        resolve(action());
                    }
                }
                catch (Throwable t)
                {
                    reject(t);
                }
            }).start();
        });
        t.call();

        return t;
    }
}

@("FutureFactory: startNew run new thread")
unittest
{
    auto futureInt = FutureFactory.startNew!int({
        import core.thread;
        import core.time;

        Thread.sleep(10.msecs);
        return 10;
    });

    const n = futureInt.await;
    assert(n == 10);
}

@("Overview: delay and await some futures")
unittest
{
    import core.time : msecs;

    Fiber delay(Duration dur)
    {
        return new Future!void(resolve => {
            import std.parallelism : taskPool, task;
            import core.thread : Thread;
            taskPool.put(task({
                Thread.sleep(dur);
                resolve();
            }));
        });
    }

    auto futureHello = new Future!string({
        delay(10.msecs).await;
        return "Hello";
    });
    auto futureWorld = new Future!string({
        delay(10.msecs).await;
        return "world";
    });

    auto futureFormat = FutureFactory.startNew!string({
        const hello = futureHello.await;
        const world = futureWorld.await;
        import std.format : format;
        return format!"%s, %s!"(hello, world);
    });
    
    const text = futureFormat.await;
    assert(text == "Hello, world!");
}

@("Overview: delay and await some logic")
unittest
{
    import core.time : msecs;

    Fiber delay(Duration dur)
    {
        return new Future!void(resolve => {
            import std.parallelism : taskPool, task;
            import core.thread : Thread;
            taskPool.put(task({
                Thread.sleep(dur);
                resolve();
            }));
        });
    }

    Fiber times(size_t n, void delegate() action)
    {
        return new Fiber({
            while (n-- > 0)
            {
                delay(10.msecs).await;
                action();
            }
        });
    }

    int count = 0;
    times(3, { count++; }).await;
    assert(count == 3);
}

struct EventLoop
{
    import std.container.dlist;

    DList!Fiber fibers;

    @disable this(this);

    void schedule(Fiber fiber)
    {
        fibers.insertBack(fiber);
    }

    void run()
    {
        while (!fibers.empty)
        {
            auto front = fibers.front;
            fibers.removeFront();
            if (front.state != Fiber.State.TERM)
            {
                front.call();
                if (front.state != Fiber.State.TERM)
                {
                    fibers.insertBack(front);
                }
            }
        }
    }
}

@("EventLoop: simple usage")
unittest
{
    import core.time;

    Fiber delay(Duration time)
    {
        import core.thread : Thread;
        return FutureFactory.startNew!void({
            Thread.sleep(time);
        });
    }

    int[] ns;
    EventLoop loop;
    loop.schedule(new Fiber({
        foreach (int i; 0 .. 3)
        {
            if (i > 0)
                delay(10.msecs).await;
            ns ~= i;
        }
    }));
    loop.schedule(new Fiber({
        foreach (int i; 10 .. 13)
        {
            if (i > 10)
                delay(10.msecs).await;
            ns ~= i;
        }
    }));

    loop.run();

    import std.format;
    assert(ns.length == 6, format!"ns.length? : %s"(ns));
}

@("Overview: use with some algorithms")
unittest
{
    import core.time : MonoTime, msecs;
    import std.conv : to;

    Fiber delay(Duration time) {
        const begin = MonoTime.currTime;
        return new Fiber({
            while (MonoTime.currTime - begin < time)
                Fiber.yield();
        });
    }

    Future!string toText(size_t n) {
        return new Future!string(resolve => {
            delay((n * 10).to!int().msecs).await;
            resolve(n.to!string());
        });
    }

    auto sumTextLength = new Future!size_t({
        import std.range : iota;
        import std.algorithm : map, sum;
        return iota(20)
            .map!(a => toText(size_t(a)).await.length) // suspend and resume in map
            .sum();
    });

    auto length = sumTextLength.await;
    assert(length > 0);
}

///
Fiber whenAll(T : Fiber)(T[] fibers)
{
    return new Fiber({
        for (;;)
        {
            bool completed = true;
            foreach (fiber; fibers)
            {
                if (fiber.state != Fiber.State.TERM)
                {
                    completed = false;
                    fiber.call();
                }
            }
            if (completed)
            {
                break;
            }
            else if (Fiber.getThis())
            {
                Fiber.yield();
            }
        }
    });
}

@("whenAll: use whenAll with some algorithms")
unittest
{
    import core.time : MonoTime, msecs;
    import std.conv : to;

    Fiber delay(Duration time) {
        const begin = MonoTime.currTime;
        return new Fiber({
            while (MonoTime.currTime - begin < time)
                Fiber.yield();
        });
    }

    Future!string toText(size_t n) {
        return new Future!string(resolve => {
            delay((n * 10).to!int().msecs).await;
            resolve(n.to!string());
        });
    }

    Future!string[] fibers;
    foreach (i; 0 .. 20)
    {
        fibers ~= toText(size_t(i));
    }
    fibers.whenAll().await;

    import std.algorithm : map, sum;

    auto length = fibers.map!(a => a.result.length).sum();
    assert(length);
}
