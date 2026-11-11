import { describe, expect, it } from 'vitest';
import { openCommand } from './open-command.ts';

describe('openCommand', () => {
  it('opens the page the browser was sent to, quoted for the shell', () => {
    expect(openCommand(new URL('http://127.0.0.1:7420/feed/sha256:abc'))).toBe("digestif open 'http://127.0.0.1:7420/feed/sha256:abc'");
    expect(openCommand(new URL("http://127.0.0.1:7420/inbox?status=new&q=it's"))).toBe(
      "digestif open 'http://127.0.0.1:7420/inbox?status=new&q=it%27s'"
    );
  });
});
