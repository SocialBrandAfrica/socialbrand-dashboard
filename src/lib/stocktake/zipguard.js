// src/lib/stocktake/zipguard.js
// The zip bomb guard for an uploaded .xlsx. An .xlsx is a zip file, and a few kilobytes of
// zip hold gigabytes of zeros. The 5 MB upload limit counts the zip, not what it unpacks to,
// so this runs BEFORE exceljs opens the file.
//
// The guard counts the bytes each entry really unpacks to. It does not trust the sizes the
// zip declares, because the sender writes those. It stops counting the moment a limit is
// passed, so a bomb costs a fraction of a second and a few megabytes, not its full size.
//
// Two limits:
//   - the whole file unpacks to MAX_UNZIPPED_BYTES or fewer bytes
//   - one worksheet XML unpacks to MAX_SHEET_XML_BYTES or fewer bytes
//
// This file imports only jszip, so the self-test script can load it straight from Node.

import JSZip from 'jszip'

export const MAX_UNZIPPED_BYTES = 50 * 1024 * 1024
export const MAX_SHEET_XML_BYTES = 20 * 1024 * 1024

const WORKSHEET_XML = /^xl\/worksheets\/[^/]+\.xml$/i

// Thrown when a limit is passed. `what` is 'sheet' (one worksheet) or 'total' (the whole file).
export class UploadTooLarge extends Error {
  constructor(what) {
    super('upload_too_large:' + what)
    this.name = 'UploadTooLarge'
    this.what = what
  }
}

// Counts the bytes one entry unpacks to, and stops once the count passes `cap`.
// Resolves with the count so far. A count above `cap` means the cap was passed.
function countUnpacked(entry, cap) {
  return new Promise((resolve, reject) => {
    let n = 0
    let settled = false
    const stream = entry.nodeStream('nodebuffer')
    stream.on('data', (chunk) => {
      if (settled) return
      n += chunk.length
      if (n > cap) {
        settled = true
        stream.destroy()
        resolve(n)
      }
    })
    stream.on('end', () => {
      if (settled) return
      settled = true
      resolve(n)
    })
    stream.on('error', (err) => {
      if (settled) return
      settled = true
      reject(err)
    })
  })
}

// buffer: the uploaded file. Resolves when the file is within both limits. Throws
// UploadTooLarge when it is not. Any other error means the file is not a readable zip.
// `limits` ({ total, sheet }) is for the self-test. The routes pass nothing.
export async function assertXlsxWithinLimits(buffer, limits) {
  const maxTotal = limits && limits.total !== undefined ? limits.total : MAX_UNZIPPED_BYTES
  const maxSheet = limits && limits.sheet !== undefined ? limits.sheet : MAX_SHEET_XML_BYTES

  const zip = await JSZip.loadAsync(buffer)

  let total = 0
  for (const entry of Object.values(zip.files)) {
    if (entry.dir) continue
    const isSheet = WORKSHEET_XML.test(entry.name)
    const cap = isSheet ? Math.min(maxSheet, maxTotal - total) : maxTotal - total
    const n = await countUnpacked(entry, cap)
    if (isSheet && n > maxSheet) throw new UploadTooLarge('sheet')
    total += n
    if (total > maxTotal) throw new UploadTooLarge('total')
  }
}
