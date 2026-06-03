export interface ImageSize {
  width: number;
  height: number;
}

export function readImageSizeFromBuffer(buffer: Buffer): ImageSize | undefined {
  return readPngSize(buffer) ?? readJpegSize(buffer);
}

export function readPngSize(buffer: Buffer): ImageSize | undefined {
  if (buffer.length < 24) return undefined;
  const isPng = buffer[0] === 0x89
    && buffer[1] === 0x50
    && buffer[2] === 0x4e
    && buffer[3] === 0x47
    && buffer[4] === 0x0d
    && buffer[5] === 0x0a
    && buffer[6] === 0x1a
    && buffer[7] === 0x0a;
  if (!isPng) return undefined;
  const width = buffer.readUInt32BE(16);
  const height = buffer.readUInt32BE(20);
  return width > 0 && height > 0 ? { width, height } : undefined;
}

export function readJpegSize(buffer: Buffer): ImageSize | undefined {
  if (buffer.length < 4 || buffer[0] !== 0xff || buffer[1] !== 0xd8) return undefined;
  let offset = 2;
  while (offset + 9 < buffer.length) {
    if (buffer[offset] !== 0xff) {
      offset += 1;
      continue;
    }

    while (buffer[offset] === 0xff) offset += 1;
    const marker = buffer[offset++];
    if (marker === undefined || marker === 0xd9 || marker === 0xda) return undefined;
    if (offset + 2 > buffer.length) return undefined;
    const segmentLength = buffer.readUInt16BE(offset);
    if (segmentLength < 2 || offset + segmentLength > buffer.length) return undefined;

    if (isJpegStartOfFrameMarker(marker)) {
      if (segmentLength < 7) return undefined;
      const height = buffer.readUInt16BE(offset + 3);
      const width = buffer.readUInt16BE(offset + 5);
      return width > 0 && height > 0 ? { width, height } : undefined;
    }

    offset += segmentLength;
  }
  return undefined;
}

function isJpegStartOfFrameMarker(marker: number): boolean {
  return (marker >= 0xc0 && marker <= 0xcf)
    && marker !== 0xc4
    && marker !== 0xc8
    && marker !== 0xcc;
}
