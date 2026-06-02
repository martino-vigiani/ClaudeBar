#!/usr/bin/env swift
import AppKit
import CoreGraphics

// make_icon.swift — trasforma un PNG full-bleed nel tile "squircle" macOS (inset + angoli
// arrotondati Apple + ombra morbida) su canvas 1024 trasparente. Output: AppIcon-masked.png.
//
// Uso: swift Scripts/make_icon.swift <source.png> <output.png>

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("uso: make_icon.swift <source.png> <output.png>\n".utf8))
    exit(1)
}
let sourcePath = args[1]
let outputPath = args[2]

guard let src = NSImage(contentsOfFile: sourcePath),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("impossibile leggere \(sourcePath)\n".utf8))
    exit(1)
}

let canvas: CGFloat = 1024
// Proporzioni macOS: tile ~824 in un canvas 1024, margine ~100 per l'ombra. Raggio ≈ 22.37%.
let margin: CGFloat = 100
let tile = canvas - margin * 2          // 824
let radius = tile * 0.2237              // ≈ 184

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: Int(canvas), height: Int(canvas),
        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    FileHandle.standardError.write(Data("impossibile creare il contesto grafico\n".utf8))
    exit(1)
}

let tileRect = CGRect(x: margin, y: margin, width: tile, height: tile)
let path = CGPath(roundedRect: tileRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 1) Ombra morbida sotto il tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44,
              color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// 2) Clip allo squircle + disegna l'art che riempie il tile.
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.draw(srcCG, in: tileRect)
ctx.restoreGState()

guard let out = ctx.makeImage() else {
    FileHandle.standardError.write(Data("render fallito\n".utf8))
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: out)
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("encode PNG fallito\n".utf8))
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: outputPath))
    print("ok → \(outputPath)")
} catch {
    FileHandle.standardError.write(Data("scrittura fallita: \(error)\n".utf8))
    exit(1)
}
