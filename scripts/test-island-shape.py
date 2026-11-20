"""Compare production GPU backdrop coverage with the production CoreGraphics path."""
from pathlib import Path
import tempfile, subprocess
root=Path(__file__).resolve().parents[1]
s=(root/'boringNotch/components/Notch/NotchOpticalSurface.swift').read_text()
s=s[s.index('// === OPTICAL_GEOMETRY_MODEL_BEGIN ==='):s.index('// === OPTICAL_GEOMETRY_MODEL_END ===')]
harness=r'''
import Foundation
import CoreGraphics
import Metal
import simd
// Measure geometry itself; the finished backdrop intentionally leaves the
// centre transparent and has fractional alpha even inside the outline.
let code = try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8) + """
fragment float4 notchCoverageProbe(NotchBackdropVertex in [[stage_in]], constant float4 *u [[buffer(0)]]) {
    float coverage = notchBackdropCoverage(in.uv * u[0].xy, u[0].xy, u[0].zw);
    return float4(coverage);
}
"""
guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {
 print("NOT VERIFIED: GPU unavailable");exit(2)
}
let library=try device.makeLibrary(source:code,options:nil)
let descriptor=MTLRenderPipelineDescriptor()
descriptor.vertexFunction=library.makeFunction(name:"notchBackdropVertex")
descriptor.fragmentFunction=library.makeFunction(name:"notchCoverageProbe")
descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
let pipeline=try device.makeRenderPipelineState(descriptor:descriptor)
for (width,height,top,bottom,convex) in [(185,32,16.0,16.0,true),(500,230,28.0,28.0,true),(24,8,28.0,28.0,true),(6,20,28.0,28.0,true),(185,32,6.0,14.0,false)] {
 let geometry=NotchSurfaceGeometry(rect:CGRect(x:0,y:0,width:width,height:height),topCornerRadius:top,bottomCornerRadius:bottom,topCornerIsConvex:convex)
 let path=geometry.makePath()
 assert(geometry.sideInset == (convex ? 0 : geometry.topCornerRadius))
 assert(geometry.topCornerRadius+geometry.bottomCornerRadius <= min(CGFloat(width)/2,CGFloat(height))+0.00001)
 let targetDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false)
 targetDescriptor.storageMode = .shared;targetDescriptor.usage = [.renderTarget,.shaderRead]
 let target=device.makeTexture(descriptor:targetDescriptor)!
 let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
 pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
 pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
 let command=queue.makeCommandBuffer()!,encoder=command.makeRenderCommandEncoder(descriptor:pass)!
 var uniforms=[SIMD4<Float>(Float(width),Float(height),Float(geometry.encodedTopRadius),Float(geometry.bottomCornerRadius)),SIMD4<Float>(0,0,1/Float(width),1/Float(height)),SIMD4<Float>(0,0,0,0)]
 encoder.setRenderPipelineState(pipeline)
 uniforms.withUnsafeMutableBytes { encoder.setFragmentBytes($0.baseAddress!,length:$0.count,index:0) }
 encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);encoder.endEncoding()
 command.commit();command.waitUntilCompleted()
 assert(command.status == .completed)
 var pixels=[UInt8](repeating:0,count:width*height*4)
 pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
 var compared=0,mismatch=0
 for y in 0..<height { for x in 0..<width {
  let alpha=pixels[(y*width+x)*4+3]
  if alpha != 0 && alpha != 255 { continue }
  let inside=path.contains(CGPoint(x:Double(x)+0.5,y:Double(y)+0.5))
  if inside != (alpha == 255) { mismatch += 1 }
  compared += 1
 } }
 assert(compared > width*height/2)
 assert(mismatch == 0,"Path/GPU coverage mismatch: \(mismatch), \(width)x\(height)")
 print("PASS: \(convex ? "island" : "legacy") \(width)x\(height), \(compared) path/GPU points agree")
}
'''
with tempfile.TemporaryDirectory(prefix='notch-island-shape-') as folder:
 p=Path(folder);(p/'main.swift').write_text('import Foundation\nimport CoreGraphics\n'+s+'\n'+harness)
 subprocess.run(['xcrun','swiftc',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(root/'boringNotch/components/Notch/NotchOpticalSurface.metal')],check=True)
