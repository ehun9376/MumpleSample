// Copyright 2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
#import <Foundation/Foundation.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
@interface MKChannelGroup : NSObject

@property (nonatomic, strong) NSString * name;
@property (nonatomic) BOOL inherited;
@property (nonatomic) BOOL inherit;
@property (nonatomic) BOOL inheritable;
@property (nonatomic, strong) NSMutableArray * members;
@property (nonatomic, strong) NSMutableArray * excludedMembers;
@property (nonatomic, strong) NSMutableArray * inheritedMembers;

@end
