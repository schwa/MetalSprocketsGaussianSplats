#import "Antimatter15SplatRenderShader.h"
#import "Antimatter15SplatTileCoverage.h"
#import "Antimatter15SplatSupport.h"
#import "SparkSplatRenderShader.h"
#import "SparkSplatSupport.h"
#import "SOGSplatSupport.h"
#import "GenericSplat.h"

#ifdef __OBJC__
#import <Foundation/Foundation.h>
@interface NSBundle (GaussianSplatModule)
+ (NSBundle *)MetalSprocketsGaussianSplatShaders;
@end
#endif
