//
//  A2BlockDelegate.m
//  A2DynamicDelegate
//
//  Created by Alexsander Akers on 11/30/11.
//  Copyright (c) 2011 Pandamonia LLC. All rights reserved.
//
//  Includes code by Apple Inc. Licensed under APSL.
//  Copyright (c) 1999-2007 Apple Inc. All rights reserved.
//

#import "A2BlockDelegate.h"
#import "A2DynamicDelegate.h"
#import <objc/message.h>

#pragma mark - Declarations and macros

#ifndef NSAlwaysAssert
	#define NSAlwaysAssert(condition, desc, ...) \
		do { if (!(condition)) { [NSException raise: NSInternalInconsistencyException format: [NSString stringWithFormat: @"%s: %@", __PRETTY_FUNCTION__, (desc)], ## __VA_ARGS__]; } } while(0)
#endif

extern Protocol *a2_dataSourceProtocol(Class cls);
extern Protocol *a2_delegateProtocol(Class cls);

@interface A2DynamicDelegate ()

@property (nonatomic, unsafe_unretained, readwrite) id realDelegate;

@end

#pragma mark - Functions

static SEL getterForProperty(Class cls, NSString *propertyName)
{
	SEL getter = NULL;

	objc_property_t property = class_getProperty(cls, propertyName.UTF8String);
	if (property)
	{
		char *getterName = property_copyAttributeValue(property, "G");
		if (getterName) getter = sel_getUid(getterName);
		free(getterName);
	}

	if (!getter)
	{
		getter = NSSelectorFromString(propertyName);
	}

	return getter;
}

static SEL setterForProperty(Class cls, NSString *propertyName)
{
	SEL setter = NULL;

	objc_property_t property = class_getProperty(cls, propertyName.UTF8String);
	if (property)
	{
		char *setterName = property_copyAttributeValue(property, "S");
		if (setterName) setter = sel_getUid(setterName);
		free(setterName);
	}

	if (!setter)
	{
		unichar firstChar = [propertyName characterAtIndex: 0];
		NSString *coda = [propertyName substringFromIndex: 1];

		setter = NSSelectorFromString([NSString stringWithFormat: @"set%c%@:", toupper(firstChar), coda]);
	}

	return setter;
}

static inline SEL prefixedSelector(SEL selector) {
	return NSSelectorFromString([@"a2_" stringByAppendingString: NSStringFromSelector(selector)]);
}

#pragma mark -

@implementation NSObject (A2BlockDelegate)

#pragma mark Helpers

+ (NSMutableDictionary *) bk_delegateNameMap
{
	NSMutableDictionary *propertyMap = objc_getAssociatedObject(self, _cmd);

	if (!propertyMap)
	{
		propertyMap = [NSMutableDictionary dictionary];
		objc_setAssociatedObject(self, _cmd, propertyMap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	return propertyMap;
}

#pragma mark Data Source

+ (void) linkCategoryBlockProperty: (NSString *) propertyName withDataSourceMethod: (SEL) selector
{
	[self linkProtocol: a2_dataSourceProtocol(self) methods: @{ propertyName : NSStringFromSelector(selector) }];
}
+ (void) linkDataSourceMethods: (NSDictionary *) dictionary
{
	[self linkProtocol: a2_dataSourceProtocol(self) methods: dictionary];
}

#pragma mark Delegate

+ (void) linkCategoryBlockProperty: (NSString *) propertyName withDelegateMethod: (SEL) selector
{
	[self linkProtocol: a2_delegateProtocol(self) methods: @{ propertyName : NSStringFromSelector(selector) }];
}
+ (void) linkDelegateMethods: (NSDictionary *) dictionary
{
	[self linkProtocol: a2_delegateProtocol(self) methods: dictionary];
}

#pragma mark Other Protocol

+ (void) linkCategoryBlockProperty: (NSString *) propertyName withProtocol: (Protocol *) protocol method: (SEL) selector
{
	[self linkProtocol: protocol methods: @{ propertyName : NSStringFromSelector(selector) }];
}
+ (void) linkProtocol: (Protocol *) protocol methods: (NSDictionary *) dictionary
{
	[dictionary enumerateKeysAndObjectsUsingBlock:^(NSString *propertyName, NSString *selectorName, __unused BOOL *stop) {
		objc_property_t property = class_getProperty(self, propertyName.UTF8String);
		NSAlwaysAssert(property, @"Property \"%@\" does not exist on class %s", propertyName, class_getName(self));

		char *dynamic = property_copyAttributeValue(property, "D");
		NSAlwaysAssert(dynamic, @"Property \"%@\" on class %s must be backed with \"@dynamic\"", propertyName, class_getName(self));
		free(dynamic);

		char *copy = property_copyAttributeValue(property, "C");
		NSAlwaysAssert(copy, @"Property \"%@\" on class %s must be defined with the \"copy\" attribute", propertyName, class_getName(self));
		free(copy);

		SEL selector = NSSelectorFromString(selectorName);
		SEL getter = getterForProperty(self, propertyName);
		SEL setter = setterForProperty(self, propertyName);

		if (class_respondsToSelector(self, setter) || class_respondsToSelector(self, getter))
			return;

		NSString *delegateProperty = nil;
		Class cls = self;
		while (!delegateProperty.length && cls != [NSObject class]) {
			delegateProperty = [cls bk_delegateNameMap][NSStringFromProtocol(protocol)];
			cls = [cls superclass];
		}

		IMP getterImplementation = imp_implementationWithBlock(^id(NSObject *self){
			return [[self dynamicDelegateForProtocol: protocol] blockImplementationForMethod: selector];
		});
		IMP setterImplementation = imp_implementationWithBlock(^void(NSObject *self, id block){
			A2DynamicDelegate *dynamicDelegate = [self dynamicDelegateForProtocol: protocol];

			if (delegateProperty.length) {
				SEL a2_setter = prefixedSelector(setterForProperty(self.class, delegateProperty));
				SEL a2_getter = prefixedSelector(getterForProperty(self.class, delegateProperty));

				if ([self respondsToSelector:a2_setter]) {
					id originalDelegate = objc_msgSend(self, a2_getter);
					if (![originalDelegate isKindOfClass:[A2DynamicDelegate class]])
						objc_msgSend(self, a2_setter, dynamicDelegate);
				}
			}
			
			[dynamicDelegate implementMethod: selector withBlock: block];
		});


		const char *getterTypes = "@@:";
		BOOL success = class_addMethod(self, getter, getterImplementation, getterTypes);
		NSAlwaysAssert(success, @"Could not implement getter for \"%@\" property.", propertyName);

		const char *setterTypes = "v@:@";
		success = class_addMethod(self, setter, setterImplementation, setterTypes);
		NSAlwaysAssert(success, @"Could not implement setter for \"%@\" property.", propertyName);
	}];
}

#pragma mark Register Dynamic Delegate

+ (void) registerDynamicDataSource
{
	[self registerDynamicDelegateNamed: @"dataSource" forProtocol: a2_dataSourceProtocol(self)];
}
+ (void) registerDynamicDelegate
{
	[self registerDynamicDelegateNamed: @"delegate" forProtocol: a2_delegateProtocol(self)];
}

+ (void) registerDynamicDataSourceNamed: (NSString *) dataSourceName
{
	[self registerDynamicDelegateNamed: dataSourceName forProtocol: a2_dataSourceProtocol(self)];
}
+ (void) registerDynamicDelegateNamed: (NSString *) delegateName
{
	[self registerDynamicDelegateNamed: delegateName forProtocol: a2_delegateProtocol(self)];
}

+ (void) registerDynamicDelegateNamed: (NSString *) delegateName forProtocol: (Protocol *) protocol
{
	NSString *protocolName = NSStringFromProtocol(protocol);
	NSMutableDictionary *propertyMap = [self bk_delegateNameMap];
	if (propertyMap[protocolName])
		return;

	SEL getter = getterForProperty(self, delegateName);
	SEL a2_getter = prefixedSelector(getter);
	SEL setter = setterForProperty(self, delegateName);
	SEL a2_setter = prefixedSelector(setter);

	IMP getterImplementation = imp_implementationWithBlock(^id(NSObject *self){
		return [[self dynamicDelegateForProtocol: protocol] realDelegate];
	});

	IMP setterImplementation = imp_implementationWithBlock(^(NSObject *self, id delegate){
		A2DynamicDelegate *dynamicDelegate = [self dynamicDelegateForProtocol: protocol];

		if ([self respondsToSelector:a2_setter]) {
			id originalDelegate = objc_msgSend(self, a2_getter, delegate);
			if (![originalDelegate isKindOfClass:[A2DynamicDelegate class]])
				objc_msgSend(self, a2_setter, dynamicDelegate);
		}

		if ([delegate isEqual: dynamicDelegate])
			delegate = nil;
		else if ([delegate isEqual:self] || [self isEqual:dynamicDelegate.realDelegate])
			delegate = [NSValue valueWithNonretainedObject: delegate];

		dynamicDelegate.realDelegate = delegate;
	});
	
	const char *getterTypes = "@@:";
	const char *setterTypes = "v@:@";

	if (!class_addMethod(self, getter, getterImplementation, getterTypes)) {
		class_addMethod(self, a2_getter, getterImplementation, getterTypes);
		Method method = class_getInstanceMethod(self, getter);
		Method a2_method = class_getInstanceMethod(self, a2_getter);
		method_exchangeImplementations(method, a2_method);
	}

	if (!class_addMethod(self, setter, setterImplementation, setterTypes)) {
		class_addMethod(self, a2_setter, setterImplementation, setterTypes);
		Method method = class_getInstanceMethod(self, setter);
		Method a2_method = class_getInstanceMethod(self, a2_setter);
		method_exchangeImplementations(method, a2_method);
	}
	
	propertyMap[protocolName] = delegateName;
}

@end

BK_MAKE_CATEGORY_LOADABLE(A2BlockDelegate)
