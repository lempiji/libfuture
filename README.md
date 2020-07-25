This is an implementation of the await concept.

It provides a mechanism to treat each nested fiber as a single fiber.

- Post-await syntax by using UFCS
- JS's Promise-like `Future!T` construction (by `resolve` and `reject`)
- C#-like `FutureFactory`

```d
auto t = new Future!int(resolve => {
        import core.thread : Thread;
        new Thread({
            Thread.sleep(1.seconds);
            resolve(100);
        }).start();
    });

auto n = t.await;
assert(n == 100);
```

```d
Future!string getHtmlAsync(string url) {
    return FutureFactory.startNew!string({
        import std.net.curl : get;
        return get(url);
    });
}

Future!size_t sumLength(string[] urls) {
    return new Future!size_t({
        size_t length = 0;
        foreach (url; urls) {
            const html = getHtmlAsync(url).await;
            length += html.length;
        }
        return length;
    });
}

Future!size_t sumLength2(string[] urls) {
    return new Future!size_t({
        import std.algorithm : map, sum;
        return urls.map!(a => getHtmlAsync(a).await.length).sum();
    });
}
```
