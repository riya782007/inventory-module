"use client";
/** Resize + re-encode an image in the browser before upload: max 1200px on
 *  the long edge, JPEG q0.82. A 4 MB phone photo becomes ~150 KB. */
export async function compressImage(file: File, maxEdge = 1200): Promise<Blob> {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height));
  const w = Math.round(bitmap.width * scale);
  const h = Math.round(bitmap.height * scale);
  const canvas = document.createElement("canvas");
  canvas.width = w; canvas.height = h;
  canvas.getContext("2d")!.drawImage(bitmap, 0, 0, w, h);
  const blob = await new Promise<Blob | null>(res =>
    canvas.toBlob(res, "image/jpeg", 0.82));
  return blob ?? file;
}
