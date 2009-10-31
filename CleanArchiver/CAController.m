/*	$Id$	*/

/*
 * Copyright (c) 2005 Inajima Daisuke All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. The name of the copyright holder may not be used to endorse or
 *    promote products derived from this software without specific prior
 *    written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER ``AS IS'' AND ANY EXPRESS
 * OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#import "Archiver.h"
#import "Bzip2.h"
#import "CAController.h"
#import "CAView.h"
#import "Dmg.h"
#import "Gzip.h"
#import "Tar.h"
#import "Zip.h"

NSString *AOArchiveIndividually	= @"Archive Individually";
NSString *AOArchiveType		= @"Archive Type";
NSString *AOExcludeDot_		= @"Exclude ._*";
NSString *AOExcludeDSS		= @"Exclude .DS_Store";
NSString *AOExcludeIcon		= @"Exclude Icon";
NSString *AOInternetEnabledDMG	= @"Internet-Enabled Disk Image";
NSString *AOReplaceAutomatically= @"Replace Automatically";
NSString *AOSaveRSRC		= @"Save Resource Fork";

@implementation CAController

#pragma mark -
#pragma mark Initializing and deallocating

+ (void)initialize
{
	NSMutableDictionary *defaults;
	NSUserDefaults *ud;
	
	defaults = [NSMutableDictionary dictionary];
	ud = [NSUserDefaults standardUserDefaults];

	[defaults setObject:@"gzip" forKey:AOArchiveType];
	[defaults setObject:[NSNumber numberWithBool:YES] forKey:AOExcludeDot_];
	[defaults setObject:[NSNumber numberWithBool:YES] forKey:AOExcludeDSS];
	[defaults setObject:[NSNumber numberWithBool:NO] forKey:AOExcludeIcon];
	[defaults setObject:[NSNumber numberWithBool:NO]
	    forKey:AOReplaceAutomatically];
	[defaults setObject:[NSNumber numberWithBool:NO]
	    forKey:AOArchiveIndividually];
	[defaults setObject:[NSNumber numberWithBool:NO]
	    forKey:AOInternetEnabledDMG];
	[defaults setObject:[NSNumber numberWithBool:YES] forKey:AOSaveRSRC];

	[ud registerDefaults:defaults];
}

- (void)awakeFromNib
{
	NSNotificationCenter *nc;
	NSUserDefaults *ud;

	nc = [NSNotificationCenter defaultCenter];
	ud = [NSUserDefaults standardUserDefaults];

	[_archiveTypeMenu selectItemWithTitle:
	    [ud objectForKey:AOArchiveType]];
	[self changeArchiveType:self];
	[_excludeDot_Check setState:[ud boolForKey:AOExcludeDot_]];
	[_excludeDSSCheck setState:[ud boolForKey:AOExcludeDSS]];
	[_excludeIconCheck setState:[ud boolForKey:AOExcludeIcon]];
	[_replaceAutomaticallyCheck setState:
	    [ud boolForKey:AOReplaceAutomatically]];
	[_archiveIndividuallyCheck
	    setState:[ud boolForKey:AOArchiveIndividually]];
	[_internetEnabledDMGCheck
	    setState:[ud boolForKey:AOInternetEnabledDMG]];
	[_saveRSRCCheck setState:[ud boolForKey:AOSaveRSRC]];

	[nc addObserver:self selector:@selector(handleFilesDropped:)
	    name:AOFilesDroppedNotification object:nil];

	[nc addObserver:self selector:@selector(handleArchiveTerminated:)
	    name:AOArchiverDidFinishArchivingNotification object:nil];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
    [_operationQueue release];
	[super dealloc];
}

#pragma mark -
#pragma mark Launching Applications

- (void)applicationWillFinishLaunching:(NSNotification *)n
{

	_operationQueue = [[NSMutableArray alloc] init];
	_archiveSessionInProgress = NO;
	_archivingCancelled = NO;
	_terminateAfterArchiving = -1;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n
{

	if (_terminateAfterArchiving == -1)
		_terminateAfterArchiving = NO;
}

#pragma mark -
#pragma mark Opening Files

- (void)application:(NSApplication *)sender openFiles:(NSArray *)filenames
{

	if (_terminateAfterArchiving == -1)
		_terminateAfterArchiving = YES;
	[self prepare:filenames];
}

#pragma mark -
#pragma mark Notification handlers

- (void)handleFilesDropped:(NSNotification *)n
{
    
	[self prepare:[n object]];
}

- (void)handleArchiveTerminated:(NSNotification *)n
{
	NSFileHandle *fh;
	NSFileManager *fm;
    
	fm = [NSFileManager defaultManager];
    
	if ([[_mainTask output] isKindOfClass:[NSFileHandle class]]) {
		fh = [_mainTask output];
		[fh truncateFileAtOffset:[fh offsetInFile]];
		[fh closeFile];
	}
    
	if (_archivingCancelled == NO && [_mainTask terminationStatus] != 0) {
		NSRunAlertPanel(@"", 
                        [NSString localizedStringWithFormat:
                         @"Can't make %@.", [_mainTask output]], 
                        nil, nil, nil);
	}
    
	[[NSWorkspace sharedWorkspace]
     noteFileSystemChanged:[_mainTask output]];
    
	[_mainTask release];
    
	if ([_operationQueue count] > 0)
		[self cleanArchive];
	else {
		[self endProgressPanel];
		_archiveSessionInProgress = NO;
		if (_terminateAfterArchiving == YES)
			[NSApp terminate:self];
	}
    
	_archivingCancelled = NO;
}

#pragma mark -
#pragma mark Closing

- (void)windowWillClose:(NSNotification *)n
{
    
	[NSApp terminate:self];
}

#pragma mark -
#pragma mark Main menu outlet actions

- (IBAction)cancelArchiving:(id)sender
{
	NSFileManager *fm;
	NSString *dst;
    
	_archivingCancelled = YES;
    
	fm = [NSFileManager defaultManager];
	dst  = [_mainTask output];
    
	[_mainTask terminate];
    
	if (![dst isEqualToString:@""])
		[fm removeFileAtPath:dst handler:nil];
}

- (IBAction)changeArchiveType:(id)sender
{
	enum archive_type type;

	type = [_archiveTypeMenu indexOfSelectedItem];
	switch (type) {
	case GZIPT:
	case BZIP2T:
		[_saveRSRCCheck setEnabled:YES];
		break;
	case ZIPT:
		[_saveRSRCCheck setState:NSOffState];
		[_saveRSRCCheck setEnabled:NO];
		break;
	case DMGT:
		[_saveRSRCCheck setState:NSOnState];
		[_saveRSRCCheck setEnabled:NO];
		break;
	}
}

- (IBAction)saveAsDefault:(id)sender
{
	NSUserDefaults *ud;

	ud = [NSUserDefaults standardUserDefaults];

	[ud setObject:[_archiveTypeMenu titleOfSelectedItem]
	    forKey:AOArchiveType];
	[ud setBool:[_excludeDot_Check state] forKey:AOExcludeDot_];
	[ud setBool:[_excludeDSSCheck state] forKey:AOExcludeDSS];
	[ud setBool:[_excludeIconCheck state] forKey:AOExcludeIcon];
	[ud setBool:[_saveRSRCCheck state] forKey:AOSaveRSRC];
	[ud setBool:[_replaceAutomaticallyCheck state]
	    forKey:AOReplaceAutomatically];
	[ud setBool:[_archiveIndividuallyCheck state]
	    forKey:AOArchiveIndividually];
	[ud setBool:[_internetEnabledDMGCheck state]
	    forKey:AOInternetEnabledDMG];
}

#pragma mark -
#pragma mark ProgressPanel actions

- (void)beginProgressPanel
{

	[_progressIndicator setIndeterminate:YES];
	[_progressIndicator startAnimation:self];
	[NSApp beginSheet:_progressWindow
	    modalForWindow:[_excludeDSSCheck window]
	    modalDelegate:self
	    didEndSelector:NULL
	    contextInfo:nil];
}

- (void)beginProgressPanelWithText:(NSString *)s
{

	[_progressMessage setStringValue:s];
	[self beginProgressPanel];
}

- (void)endProgressPanel
{

	[_progressWindow orderOut:self];
	[NSApp endSheet:_progressWindow];
}

#pragma mark -
#pragma mark Treating filenames

- (NSString *)getFileNameWithCandidate:(NSString *)name
{
	NSFileManager *fm;
	NSSavePanel *sp;
	NSString *basename, *dirname;
	int spStatus;

	if (name == nil)
		return name;

	fm = [NSFileManager defaultManager];
	sp = [NSSavePanel savePanel];
	basename = [name lastPathComponent];
	dirname = [name stringByDeletingLastPathComponent];

	if ([fm fileExistsAtPath:name] || [dirname isEqualToString:@""] ) {
		spStatus = [sp runModalForDirectory:dirname file:basename];
		if (spStatus == NSFileHandlingPanelOKButton)
			return [sp filename];
		else
			return nil;
	} else
		return name;
}

- (NSString *)getArchiveFileNameWithSourceFileNames:(NSArray *)srcnames
    withArchiveType:(enum archive_type)type withReplaceAutomatically:(BOOL)ra
{
	NSFileManager *fm;
	NSString *dstname, *ext, *srcname;
	BOOL isDir;

	fm = [NSFileManager defaultManager];

	if ((srcname = [srcnames objectAtIndex:0]) == nil)
		return nil;

	[fm fileExistsAtPath:srcname isDirectory:&isDir];

	switch (type) {
	case GZIPT:
		if ([srcnames count] == 1 && !isDir)
			ext = @"gz";
		else
			ext = @"tar.gz";
		break;
	case BZIP2T:
		if ([srcnames count] == 1 && !isDir)
			ext = @"bz2";
		else
			ext = @"tar.bz2";
		break;
	case ZIPT:
		ext = @"zip";
		break;
	case DMGT:
		if (!isDir) {
			NSRunAlertPanel(@"", NSLocalizedString(
			    @"You can make a disk image only from a folder.", nil),
			    nil, nil, nil);
			return nil;
		}
		ext = @"dmg";
		break;
	default:
		exit(1);
	}

	if ([srcnames count] == 1) {
		dstname = [srcname stringByAppendingPathExtension:ext];
		if (!ra)
			dstname = [self getFileNameWithCandidate:dstname];
	} else
		dstname = [self getFileNameWithCandidate:
		    [@"Archive" stringByAppendingPathExtension:ext]];

	return dstname;
}

- (NSFileHandle *)getFileHandleOfFile:(NSString *)filename // ???: What purpose of this method?
{
	NSFileManager *fm;
    
	fm = [NSFileManager defaultManager];
    
	if (![fm fileExistsAtPath:filename])
		[fm createFileAtPath:filename
                    contents:nil attributes:nil];
	return [NSFileHandle fileHandleForWritingAtPath:filename];
}

#pragma mark -
#pragma mark Compressing and extracting

- (void)prepare:(NSArray *)srcs
{
	NSFileManager *fm;
	NSMutableDictionary *status;
	NSString *dst, *src;
	enum archive_type type;
	int i;
	BOOL ai, e_, ed, ei, er, ie, ra;

	status = [[NSMutableDictionary alloc] init];

	fm = [NSFileManager defaultManager];
	type = [_archiveTypeMenu indexOfSelectedItem];
	src = [srcs objectAtIndex:0];
	ai = [_archiveIndividuallyCheck state];
	e_ = [_excludeDot_Check state];
	ed = [_excludeDSSCheck state];
	ei = [_excludeIconCheck state];
	er = [_saveRSRCCheck state];
	ie = [_internetEnabledDMGCheck state];
	ra = [_replaceAutomaticallyCheck state];

	[status setObject:[NSNumber numberWithInt:type] forKey:AOArchiveType];
	[status setObject:[NSNumber numberWithBool:e_] forKey:AOExcludeDot_];
	[status setObject:[NSNumber numberWithBool:ed] forKey:AOExcludeDSS];
	[status setObject:[NSNumber numberWithBool:ei] forKey:AOExcludeIcon];
	[status setObject:[NSNumber numberWithBool:er] forKey:AOSaveRSRC];
	[status setObject:[NSNumber numberWithBool:ie]
	    forKey:AOInternetEnabledDMG];

	if (ai) {
		for (i = 0; i < [srcs count]; i++) {
			src = [srcs objectAtIndex:i];

			[status setObject:[NSArray arrayWithObject:src]
			        forKey:@"srcs"];

			dst = [self getArchiveFileNameWithSourceFileNames:
			    [NSArray arrayWithObject:src]
			    withArchiveType:type withReplaceAutomatically:ra];
			if (dst != nil) {
				[status setObject:dst forKey:@"dst"];
				[_operationQueue addObject:
				    [NSDictionary
					dictionaryWithDictionary:status]];
			}
		}
	} else {
		[status setObject:srcs forKey:@"srcs"];

		dst = [self getArchiveFileNameWithSourceFileNames:srcs
			withArchiveType:type withReplaceAutomatically:ra];
		if (dst != nil) {
			[status setObject:dst forKey:@"dst"];
			[_operationQueue addObject:
			    [NSDictionary dictionaryWithDictionary:status]];
		}
	}

	if (_archiveSessionInProgress == NO && [_operationQueue count] > 0) {
		_archiveSessionInProgress = YES;
		[self beginProgressPanelWithText:
		    NSLocalizedString(@"Preparing...", nil)];
		[self cleanArchive];
	} else if (_terminateAfterArchiving == YES)
		[NSApp terminate:self];

	[status release];
}

- (void)cleanArchive
{
	NSArray *srcs;
	NSDictionary *status;
	NSFileManager *fm;
	NSMutableArray *exfiles;
	NSMutableArray *srcbases;
	NSString *dst;
	enum archive_type type;
	int i;
	BOOL isDir;

	exfiles = [[NSMutableArray alloc] init];
	fm = [NSFileManager defaultManager];

	status = [_operationQueue objectAtIndex:0];
	[status retain];
	[_operationQueue removeObjectAtIndex:0];

	type = [[status objectForKey:AOArchiveType] intValue];
	dst = [status objectForKey:@"dst"];
	srcs = [status objectForKey:@"srcs"];
	[fm fileExistsAtPath:[srcs objectAtIndex:0] isDirectory:&isDir];

	if ([[status objectForKey:AOExcludeDot_] intValue])
		[exfiles addObject:@"._*"];

	if ([[status objectForKey:AOExcludeDSS] intValue])
		[exfiles addObject:@".DS_Store"];

	if ([[status objectForKey:AOExcludeIcon] intValue])
		[exfiles addObject:@"Icon\r"];

	switch (type) {
	case GZIPT:
		if ([srcs count] == 1 && !isDir) {
			_mainTask = [[Gzip alloc] init];
			[_mainTask setArchiveMode:GZIP];
		} else {
			_mainTask = [[Tar alloc] init];
			[_mainTask setArchiveMode:TAR_GZIP];
		}
		break;
	case BZIP2T:
		if ([srcs count] == 1 && !isDir) {
			_mainTask = [[Bzip2 alloc] init];
			[_mainTask setArchiveMode:BZIP2];
		} else {
			_mainTask = [[Tar alloc] init];
			[_mainTask setArchiveMode:TAR_BZIP2];
		}
		break;
	case ZIPT:
		_mainTask = [[Zip alloc] init];
		[_mainTask setArchiveMode:ZIP];
		break;
	case DMGT:
		_mainTask = [[Dmg alloc] init];
		if ([[status objectForKey:AOInternetEnabledDMG] boolValue])
			[_mainTask setArchiveMode:DMG_CREATE_IE];
		else
			[_mainTask setArchiveMode:DMG_CREATE];
		break;
	default:
		exit(1);
	}

	if ([[status objectForKey:AOSaveRSRC] intValue])
		[_mainTask setSavingResourceFork:YES];
	else
		[_mainTask setSavingResourceFork:NO];

	if ([srcs count] == 1)
		[_mainTask setInput:[[srcs objectAtIndex:0] lastPathComponent]];
	else {
		srcbases = [[NSMutableArray alloc] init];

		for (i = 0; i < [srcs count]; i++)
			[srcbases addObject:
			    [[srcs objectAtIndex:i] lastPathComponent]];

		[_mainTask setInput:srcbases];

		[srcbases release];
	}
	[_mainTask setCurrentDirectoryPath:
	    [[srcs objectAtIndex:0] stringByDeletingLastPathComponent]];
	[_mainTask setOutput:dst];
	[_mainTask setExcludedFiles:exfiles];
	[_mainTask launch];

	[_progressMessage setStringValue:
		[NSString 
		    stringWithFormat:NSLocalizedString(@"Archiving: %@", nil),
		    [dst lastPathComponent]]];

	[exfiles release];
	[status release];
}


@end