import { describe, expect, it } from "vitest";
import { readImageSizeFromBuffer, readJpegSize, readPngSize } from "./image-size.js";

function pngBuffer(width: number, height: number): Buffer {
  const buffer = Buffer.alloc(24);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(buffer, 0);
  buffer.writeUInt32BE(width, 16);
  buffer.writeUInt32BE(height, 20);
  return buffer;
}

function jpegSof0Buffer(width: number, height: number): Buffer {
  const buffer = Buffer.alloc(23);
  buffer[0] = 0xff;
  buffer[1] = 0xd8;
  buffer[2] = 0xff;
  buffer[3] = 0xc0;
  buffer.writeUInt16BE(17, 4);
  buffer[6] = 0x08;
  buffer.writeUInt16BE(height, 7);
  buffer.writeUInt16BE(width, 9);
  buffer[21] = 0xff;
  buffer[22] = 0xd9;
  return buffer;
}

describe("image size parsing", () => {
  it("reads PNG dimensions from the IHDR header", () => {
    expect(readPngSize(pngBuffer(1920, 1080))).toEqual({ width: 1920, height: 1080 });
    expect(readImageSizeFromBuffer(pngBuffer(320, 240))).toEqual({ width: 320, height: 240 });
  });

  it("rejects invalid or degenerate PNG buffers", () => {
    expect(readPngSize(Buffer.alloc(23))).toBeUndefined();
    expect(readPngSize(Buffer.from("not a png"))).toBeUndefined();
    expect(readPngSize(pngBuffer(0, 100))).toBeUndefined();
    expect(readPngSize(pngBuffer(100, 0))).toBeUndefined();
  });

  it("reads JPEG dimensions from a start-of-frame segment", () => {
    expect(readJpegSize(jpegSof0Buffer(4032, 3024))).toEqual({ width: 4032, height: 3024 });
    expect(readImageSizeFromBuffer(jpegSof0Buffer(640, 480))).toEqual({ width: 640, height: 480 });
  });

  it("rejects truncated JPEG buffers", () => {
    expect(readJpegSize(Buffer.from([0xff, 0xd8, 0xff, 0xc0, 0x00]))).toBeUndefined();
  });

  it("stops before scan data when no size-bearing frame was found", () => {
    const buffer = Buffer.from([0xff, 0xd8, 0xff, 0xda, 0x00, 0x02, 0x00, 0x00]);
    expect(readJpegSize(buffer)).toBeUndefined();
  });

  it("returns undefined for non-image buffers", () => {
    expect(readImageSizeFromBuffer(Buffer.from("hello"))).toBeUndefined();
  });
});
