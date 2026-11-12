#import <Foundation/Foundation.h>
#include "objcCompanion.h"

int matrixObjcLength(void) {
	NSString *text = [NSString stringWithUTF8String:"matrix"];
	NSArray *parts = [NSArray arrayWithObjects:text, @"objc", nil];
	return (int)[text length] + (int)[parts count];
}
