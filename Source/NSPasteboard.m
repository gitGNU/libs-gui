/** <title>NSPasteboard</title>

   <abstract>Implementation of class for communicating with the
			pasteboard server.</abstract>

   Copyright (C) 1997,1999 Free Software Foundation, Inc.

   Author: Richard Frith-Macdonald <richard@brainstorm.co.uk>
   Date: 1997
   
   This file is part of the GNUstep GUI Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.
   
   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Library General Public
   License along with this library; see the file COPYING.LIB.
   If not, write to the Free Software Foundation,
   59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
*/ 

#include "gnustep/gui/config.h"
#include "AppKit/NSPasteboard.h"
#include "AppKit/NSApplication.h"
#include "AppKit/NSWorkspace.h"
#include "AppKit/NSFileWrapper.h"
#include <Foundation/NSArray.h>
#include <Foundation/NSData.h>
#include <Foundation/NSHost.h>
#include <Foundation/NSDictionary.h>
#include <Foundation/NSConnection.h>
#include <Foundation/NSDistantObject.h>
#include <Foundation/NSMapTable.h>
#include <Foundation/NSNotification.h>
#include <Foundation/NSException.h>
#include <Foundation/NSLock.h>
#include <Foundation/NSPathUtilities.h>
#include <Foundation/NSPortNameServer.h>
#include <Foundation/NSProcessInfo.h>
#include <Foundation/NSSerialization.h>
#include <Foundation/NSUserDefaults.h>
#include <Foundation/NSMethodSignature.h>
#include <Foundation/NSRunLoop.h>
#include <Foundation/NSTask.h>
#include <Foundation/NSTimer.h>

#include "gnustep/gui/GSPasteboardServer.h"

@interface NSPasteboard (Private)
+ (id<GSPasteboardSvr>) _pbs;
+ (NSPasteboard*) _pasteboardWithTarget: (id<GSPasteboardObj>)aTarget
				   name: (NSString*)aName;
- (id) _target;
@end

@implementation NSPasteboard

static	NSLock			*dictionary_lock = nil;
static	NSMutableDictionary	*pasteboards = nil;
static	id<GSPasteboardSvr>	the_server = nil;
static  NSMapTable              *mimeMap = NULL;

//
// Class methods
//
+ (void) initialize
{
  if (self == [NSPasteboard class])
    {
      // Initial version
      [self setVersion: 1];
      dictionary_lock = [[NSLock alloc] init];
      pasteboards = [[NSMutableDictionary alloc] initWithCapacity: 8];
    }
}

/*
 *	Special method to use a local server rather than connecting over DO
 */
+ (void) _localServer: (id<GSPasteboardSvr>)s
{
  the_server = s;
}

+ (id) _lostServer: (NSNotification*)notification
{
  id	obj = the_server;

  the_server = nil;
  [[NSNotificationCenter defaultCenter]
    removeObserver: self
	      name: NSConnectionDidDieNotification
	    object: [notification object]];
  RELEASE(obj);
  return self;
}

+ (id<GSPasteboardSvr>) _pbs
{
  if (the_server == nil)
    {
      NSString	*host;
      NSString	*description;

      host = [[NSUserDefaults standardUserDefaults] stringForKey: @"NSHost"];
      if (host == nil)
	{
	  host = @"";
	}
      else
	{
	  NSHost	*h;

	  /*
	   * If we have a host specified, but it is the current host,
	   * we do not need to ask for a host by name (nameserver lookup
	   * can be faster) and the empty host name can be used to
	   * indicate that we may start a pasteboard server locally.
	   */
	  h = [NSHost hostWithName: host];
	  if (h == nil)
	    {
	      NSLog(@"Unknown NSHost (%@) ignored", host);
	      host = @"";
	    }
	  else if ([h isEqual: [NSHost currentHost]] == YES)
	    {
	      host = @"";
	    }
	  else
	    {
	      host = [h name];
	    }
	}

      if ([host length] == 0)
	{
	  description = @"local host";
	}
      else
	{
	  description = host;
	}

      the_server = (id<GSPasteboardSvr>)[NSConnection
	rootProxyForConnectionWithRegisteredName: PBSNAME host: host];
      if (the_server == nil && [host length] > 0)
	{
	  NSString	*service;

	  service = [PBSNAME stringByAppendingFormat: @"-%@", host];
	  the_server = (id<GSPasteboardSvr>)[NSConnection
	    rootProxyForConnectionWithRegisteredName: service host: @"*"];
	}

      if (RETAIN((id)the_server) != nil)
	{
	  NSConnection*	conn = [(id)the_server connectionForProxy];

	  [[NSNotificationCenter defaultCenter]
	    addObserver: self
	       selector: @selector(_lostServer:)
		   name: NSConnectionDidDieNotification
		 object: conn];
	}
      else
	{
	  static BOOL		recursion = NO;
	  static NSString	*cmd = nil;
	  static NSArray	*args = nil;

	  if (cmd == nil && recursion ==NO)
	    {
#ifdef GNUSTEP_BASE_LIBRARY
	      cmd = RETAIN([[NSSearchPathForDirectoriesInDomains(
		GSToolsDirectory, NSSystemDomainMask, YES) objectAtIndex: 0]
		stringByAppendingPathComponent: @"gpbs"]);
#else
	      cmd = RETAIN([[@GNUSTEP_INSTALL_PREFIX 
		stringByAppendingPathComponent: @"Tools"] 
		stringByAppendingPathComponent: @"gpbs"]);
#endif
	    }
	  if (recursion == YES || cmd == nil)
	    {
	      NSLog(@"Unable to contact pasteboard server - "
		@"please ensure that gpbs is running for %@.", description);
	      return nil;
	    }
	  else
	    {
	      NSLog(@"\nI couldn't contact the pasteboard server for %@ -\n"
@"so I'm attempting to to start one - which will take a few seconds.\n"
@"Trying to launch gpbs from %@ or a machine/operating-system subdirectory.\n"
@"It is recommended that you start the pasteboard server (gpbs) when\n"
@"your windowing system is started up.\n", description,
[cmd stringByDeletingLastPathComponent]);
	      if ([host length] > 0)
		{
		  args = [[NSArray alloc] initWithObjects:
		    @"-NSHost", host, nil];
		}
	      [NSTask launchedTaskWithLaunchPath: cmd arguments: args];
	      [NSTimer scheduledTimerWithTimeInterval: 5.0
					   invocation: nil
					      repeats: NO];
	      [[NSRunLoop currentRunLoop] runUntilDate: 
		[NSDate dateWithTimeIntervalSinceNow: 5.0]];
	      recursion = YES;
	      [self _pbs];
	      recursion = NO;
	    }
	}
    }
  return the_server;
}

/*
 * Creating and Releasing an NSPasteboard Object
 */
+ (NSPasteboard*) _pasteboardWithTarget: (id<GSPasteboardObj>)aTarget
				   name: (NSString*)aName
{
  NSPasteboard*	p = nil;

  [dictionary_lock lock];
  p = [pasteboards objectForKey: aName];
  if (p)
    {
      /*
       * It is conceivable that the following may have occurred -
       * 1. The pasteboard was created on the server
       * 2. We set up an NSPasteboard to point to it
       * 3. The pasteboard on the server was destroyed by a [-releaseGlobally]
       * 4. The named pasteboard was asked for again - resulting in a new
       *	object being created on the server.
       * If this is the case, our proxy for the object on the server will be
       *	out of date, so we swap it for the newly created one.
       */
      if (p->target != (id)aTarget)
	{
	  AUTORELEASE(p->target);
	  p->target = RETAIN((id)aTarget);
	}
    }
  else
    {
      /*
       * For a newly created NSPasteboard object, we must make an entry
       * in the dictionary so we can look it up safely.
       */
      p = [NSPasteboard alloc];
      if (p)
	{
	  p->target = RETAIN((id)aTarget);
	  p->name = RETAIN(aName);
	  [pasteboards setObject: p forKey: aName];
	  AUTORELEASE(p);
	}
      /*
       * The AUTORELEASE ensures that the NSPasteboard object we are
       * returning will be released once our caller has finished with it.
       * This is necessary so that our RELEASE method will be called to
       * remove the NSPasteboard from the 'pasteboards' array when it is not
       * needed any more.
       */
    }
  [dictionary_lock unlock];
  return p;
}

+ (NSPasteboard*) generalPasteboard
{
  return [self pasteboardWithName: NSGeneralPboard];
}

+ (NSPasteboard*) pasteboardWithName: (NSString*)aName
{
  NS_DURING
    {
      id<GSPasteboardObj>	anObj;

      anObj = [[self _pbs] pasteboardWithName: aName];
      if (anObj)
	{
	  NSPasteboard	*ret;

	  ret = [self _pasteboardWithTarget: anObj name: aName];
	  NS_VALRETURN(ret);
	}
    }
  NS_HANDLER
    {
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER

  return nil;
}

+ (NSPasteboard*) pasteboardWithUniqueName
{
  NS_DURING
    {
      id<GSPasteboardObj>	anObj;

      anObj = [[self _pbs] pasteboardWithUniqueName];
      if (anObj)
	{
	  NSString	*aName;

	  aName = [anObj name];
	  if (aName)
	    {
	      NSPasteboard	*ret;

	      ret = [self _pasteboardWithTarget: anObj name: aName];
	      NS_VALRETURN(ret);
	    }
	}
    }
  NS_HANDLER
    {
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER

  return nil;
}

/*
 * Getting Data in Different Formats 
 */
+ (NSPasteboard*) pasteboardByFilteringData: (NSData*)data
				     ofType: (NSString*)type
{
  NS_DURING
    {
      id<GSPasteboardObj>	anObj;

      anObj = [[self _pbs] pasteboardByFilteringData: data
					      ofType: type
					      isFile: NO];
      if (anObj)
	{
	  NSString 	*aName;

	  aName = [anObj name];
	  if (aName)
	    {
	      NSPasteboard	*ret;

	      ret = [self _pasteboardWithTarget: anObj name: aName];
	      NS_VALRETURN(ret);
	    }
	}
    }
  NS_HANDLER
    {
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER

  return nil;
}

+ (NSPasteboard*) pasteboardByFilteringFile: (NSString*)filename
{
  NSData	*data;
  NSString	*type;

  data = [NSData dataWithContentsOfFile: filename];
  type = NSCreateFileContentsPboardType([filename pathExtension]);
  NS_DURING
    {
      id<GSPasteboardObj>	anObj;

      anObj = [[self _pbs] pasteboardByFilteringData: data
					       ofType: type
					       isFile: YES];
      if (anObj)
	{
	  NSString	*aName;

	  aName = [anObj name];
	  if (aName)
	    {
	      NSPasteboard	*ret;

	      ret = [self _pasteboardWithTarget: anObj name: aName];
	      NS_VALRETURN(ret);
	    }
	}
    }
  NS_HANDLER
    {
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER

  return nil;
}

+ (NSPasteboard*) pasteboardByFilteringTypesInPasteboard: (NSPasteboard*)pboard
{
  NS_DURING
    {
      id<GSPasteboardObj>	anObj;

      anObj = [pboard _target];
      if (anObj)
	{
	  anObj = [[self _pbs] pasteboardByFilteringTypesInPasteboard: anObj];
	  if (anObj)
	    {
	      NSString	*aName;

	      aName = [anObj name];
	      if (aName)
		{
		  NSPasteboard	*ret;

		  ret = [self _pasteboardWithTarget: anObj
					       name: (NSString*)aName];
		  NS_VALRETURN(ret);
		}
	    }
	}
    }
  NS_HANDLER
    {
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER

  return nil;
}

+ (NSArray*) typesFilterableTo: (NSString*)type
{
  NSArray*	types = nil;

  NS_DURING
    {
      types = [[self _pbs] typesFilterableTo: type];
    }
  NS_HANDLER
    {
      types = nil;
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER
  return types;
}

/*
 * Instance methods
 */

- (id) _target
{
  return target;
}

/*
 * Creating and Releasing an NSPasteboard Object
 */

- (void) dealloc
{
  RELEASE(target);
  RELEASE(name);
  [super dealloc];
}

- (void) releaseGlobally
{
  [target releaseGlobally];
  [pasteboards removeObjectForKey: name];
}

/*
 * Referring to a Pasteboard by Name 
 */
- (NSString*) name
{
  return name;
}

/*
 * Writing Data 
 */
- (int) addTypes: (NSArray*)newTypes
	   owner: (id)newOwner
{
  int	count = 0;

  NS_DURING
    {
      count = [target addTypes: newTypes
			 owner: newOwner
		    pasteboard: self
		      oldCount: changeCount];
      if (count > 0)
	{
	  changeCount = count;
	}
    }
  NS_HANDLER
    {
      count = 0;
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER
  return count;
}

- (int) declareTypes: (NSArray*)newTypes
	       owner: (id)newOwner
{
  NS_DURING
    {
      changeCount = [target declareTypes: newTypes
				   owner: newOwner
			      pasteboard: self];
    }
  NS_HANDLER
    {
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER
  return changeCount;
}

/*
 *	Hack to ensure correct release of NSPasteboard objects -
 *	If we are released such that the only thing retaining us
 *	is the pasteboards dictionary, remove us from that dictionary
 *	as well.
 */
- (void) release
{
  if ([self retainCount] == 2)
    {
      [dictionary_lock lock];
      RETAIN(super);
      [pasteboards removeObjectForKey: name];
      RELEASE(super);
      [dictionary_lock unlock];
    }
  RELEASE(super);
}

- (BOOL) setData: (NSData*)data
	 forType: (NSString*)dataType
{
  BOOL	ok = NO;

  NS_DURING
    {
      ok = [target setData: data
		   forType: dataType
		    isFile: NO
		  oldCount: changeCount];
    }
  NS_HANDLER
    {
      ok = NO;
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER
  return ok;
}

- (BOOL) setPropertyList: (id)propertyList
		 forType: (NSString*)dataType
{
  NSData	*d = [NSSerializer serializePropertyList: propertyList];

  return [self setData: d forType: dataType];
}

- (BOOL) setString: (NSString*)string
	   forType: (NSString*)dataType
{
  return [self setPropertyList: string forType: dataType];
}

- (BOOL) writeFileContents: (NSString*)filename
{
  NSFileWrapper *wrapper;
  NSData	*data;
  NSString	*type;
  BOOL		ok = NO;

  wrapper = [[NSFileWrapper alloc] initWithPath: filename];
  data = [wrapper serializedRepresentation];
  RELEASE(wrapper);
  type = NSCreateFileContentsPboardType([filename pathExtension]);
  NS_DURING
    {
      ok = [target setData: data
		   forType: type
		    isFile: YES
		  oldCount: changeCount];
    }
  NS_HANDLER
    {
      ok = NO;
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER
  return ok;
}

- (BOOL) writeFileWrapper: (NSFileWrapper *)wrapper
{
  NSString	*filename = [wrapper preferredFilename];
  NSData	*data;
  NSString	*type;
  BOOL		ok = NO;

  if (filename == nil)
    {
      [NSException raise: NSInvalidArgumentException
		  format: @"Cannot put file on pastboard with "
	@"no preferred filename"];
    }

  data = [wrapper serializedRepresentation];
  type = NSCreateFileContentsPboardType([filename pathExtension]);
  NS_DURING
    {
      ok = [target setData: data
		   forType: type
		    isFile: YES
		  oldCount: changeCount];
    }
  NS_HANDLER
    {
      ok = NO;
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER
  return ok;
}

/*
 * Determining Types 
 */
- (NSString*) availableTypeFromArray: (NSArray*)types
{
  NSString *type = nil;

  NS_DURING
    {
      int	count = 0;

      type = [target availableTypeFromArray: types
				changeCount: &count];
      changeCount = count;
    }
  NS_HANDLER
    {
      type = nil;
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER
  return type;
}

- (NSArray*) types
{
  NSArray *result = nil;

  NS_DURING
    {
      int	count = 0;

      result = [target typesAndChangeCount: &count];
      changeCount = count;
    }
  NS_HANDLER
    {
      result = nil;
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER
  return result;
}

/*
 * Reading Data 
 */
- (int) changeCount
{
  NS_DURING
    {
      int	count;

      count = [target changeCount];
      changeCount = count;
    }
  NS_HANDLER
    {
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER
  return changeCount;
}

- (NSData*) dataForType: (NSString*)dataType
{
  NSData	*d = nil;

  NS_DURING
    {
      d = [target dataForType: dataType
		     oldCount: changeCount
		mustBeCurrent: (useHistory == NO) ? YES : NO];
    }
  NS_HANDLER
    {
      d = nil;
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER
  return d;
}

- (id) propertyListForType: (NSString*)dataType
{
  NSData	*d = [self dataForType: dataType];

  if (d)
    return [NSDeserializer deserializePropertyListFromData: d
					 mutableContainers: NO];
  else
    return nil;
}

- (NSString*) readFileContentsType: (NSString*)type
			    toFile: (NSString*)filename
{
  NSData	*d;
  NSFileWrapper *wrapper;

  if (type == nil)
    {
      type = NSCreateFileContentsPboardType([filename pathExtension]);
    }
  d = [self dataForType: type];
  if (d == nil)
    {
      d = [self dataForType: NSFileContentsPboardType];
      if (d == nil)
	return nil;
    }

  wrapper = [[NSFileWrapper alloc] initWithSerializedRepresentation: d];
  if ([wrapper writeToFile: filename atomically: NO updateFilenames: NO] == NO)
    {
      RELEASE(wrapper);
      return nil;
    }
  RELEASE(wrapper);
  return filename;
}

- (NSFileWrapper *)readFileWrapper
{
  NSData *d = [self dataForType: NSFileContentsPboardType];

  if (d == nil)
    return nil;

  return
    AUTORELEASE([[NSFileWrapper alloc] initWithSerializedRepresentation: d]);
}

- (NSString*) stringForType: (NSString*)dataType
{
  return [self propertyListForType: dataType];
}

/*
 * Methods Implemented by the Owner 
 */
- (void) pasteboard: (NSPasteboard*)sender
 provideDataForType: (NSString*)type
{
}

- (void) pasteboard: (NSPasteboard*)sender
 provideDataForType: (NSString*)type
	 andVersion: (int)version
{
}

- (void) pasteboardChangedOwner: (NSPasteboard*)sender
{
}

@end

@implementation NSPasteboard (GNUstepExtensions)

/*
 *	Once the '[-setChangeCount: ]' message has been sent to an NSPasteboard
 *	the object will gain an extra GNUstep behaviour - when geting data
 *	from the pasteboard, the data need no longer be from the latest
 *	version but may be a version from a previous representation with
 *	the specified change count.
 */
- (void) setChangeCount: (int)count
{
  useHistory = YES;
  changeCount = count;
}

- (void) setHistory: (unsigned)length
{
  NS_DURING
    {
      [target setHistory: length];
    }
  NS_HANDLER
    {
      [NSException raise: NSPasteboardCommunicationException
		  format: @"%@", [localException reason]];
    }
  NS_ENDHANDLER
}

+ (void) _initMimeMappings
{
  mimeMap = NSCreateMapTable(NSObjectMapKeyCallBacks,
    NSObjectMapValueCallBacks, 0);

  NSMapInsert(mimeMap, (void *)NSStringPboardType,
    (void *)@"text/plain");
  NSMapInsert(mimeMap, (void *)NSFileContentsPboardType, 
    (void *)@"text/plain");
  NSMapInsert(mimeMap, (void *)NSFilenamesPboardType, 
    (void *)@"text/uri-list");
  NSMapInsert(mimeMap, (void *)NSPostScriptPboardType, 
    (void *)@"application/postscript");
  NSMapInsert(mimeMap, (void *)NSTabularTextPboardType, 
    (void *)@"text/tab-separated-values");
  NSMapInsert(mimeMap, (void *)NSRTFPboardType,
    (void *)@"text/richtext");
  NSMapInsert(mimeMap, (void *)NSTIFFPboardType,
    (void *)@"image/tiff");
  NSMapInsert(mimeMap, (void *)NSGeneralPboardType,
    (void *)@"text/plain");
}

/*
 * Return the mapping for pasteboard->mime, or return the original pasteboard
 * type if no mapping is found
 */
+ (NSString *) mimeTypeForPasteboardType: (NSString *)type
{
  NSString	*mime;

  if (mimeMap == NULL)
    {
      [self _initMimeMappings];
    }
  mime = NSMapGet(mimeMap, (void *)type);
  if (mime == nil)
    {
      mime = type;
    }
  return mime;
}

/*
 * Return the mapping for mime->pasteboard, or return the original pasteboard
 * type if no mapping is found. This method may not have a one-to-one 
 * mapping
 */
+ (NSString *) pasteboardTypeForMimeType: (NSString *)mimeType
{
  BOOL			found;
  NSString		*type;
  NSString		*mime;
  NSMapEnumerator	enumerator;
  
  if (mimeMap == NULL)
    {
      [self _initMimeMappings];
    }
  enumerator = NSEnumerateMapTable(mimeMap);
  while ((found = NSNextMapEnumeratorPair(&enumerator, 
    (void **)(&type), (void **)(&mime))))
    {
      if ([mimeType isEqual: mime])
	{
	  break;
	}
    }

  if (found == NO)
    {
      type = mimeType;
    }
  return type;
}

@end

@implementation NSURL (NSPasteboard)
+ (NSURL *) URLFromPasteboard: (NSPasteboard *)pasteBoard
{
  return [self URLWithString: [pasteBoard stringForType: NSURLPboardType]];
}

- (void) writeToPasteboard: (NSPasteboard *)pasteBoard
{
  [pasteBoard setString: [self absoluteString]
	      forType: NSURLPboardType];
}

@end


static NSString*	contentsPrefix = @"NSTypedFileContentsPboardType:";
static NSString*	namePrefix = @"NSTypedFilenamesPboardType:";

NSString*
NSCreateFileContentsPboardType(NSString *fileType)
{
  return [NSString stringWithFormat: @"%@%@", contentsPrefix, fileType];
}

NSString*
NSCreateFilenamePboardType(NSString *filename)
{
  return [NSString stringWithFormat: @"%@%@", namePrefix, filename];
}

NSString*
NSGetFileType(NSString *pboardType)
{
  if ([pboardType hasPrefix: contentsPrefix])
    {
      return [pboardType substringFromIndex: [contentsPrefix length]];
    }
  if ([pboardType hasPrefix: namePrefix])
    {
      return [pboardType substringFromIndex: [namePrefix length]];
    }
  return nil;
}

NSArray*
NSGetFileTypes(NSArray *pboardTypes)
{
  NSMutableArray *a = [NSMutableArray arrayWithCapacity: [pboardTypes count]];
  unsigned int	i;

  for (i = 0; i < [pboardTypes count]; i++)
    {
      NSString	*s = NSGetFileType([pboardTypes objectAtIndex: i]);

      if (s && ! [a containsObject: s])
	{
	  [a addObject: s];
	}
    }
  if ([a count] > 0)
    {
      return AUTORELEASE([a copy]);
    }
  return nil;
}

