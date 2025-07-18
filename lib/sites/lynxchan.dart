// ignore_for_file: argument_type_not_assignable
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:chan/models/flag.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/attachment.dart';
import 'package:chan/services/util.dart';
import 'package:chan/sites/helpers/http_304.dart';

import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/lainchan.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart';
import 'package:html/dom.dart' as dom;
import 'package:mime/mime.dart';

class SiteLynxchan extends ImageboardSite with Http304CachingThreadMixin {
	@override
	final String name;
	@override
	final String baseUrl;
	@override
	final String defaultUsername;
	final List<ImageboardBoard>? boards;
	@override
	final bool hasLinkCookieAuth;

	static final _quoteLinkPattern = RegExp(r'^\/([^\/]+)\/\/?res\/(\d+).html#(\d+)');

	static PostNodeSpan makeSpan(String board, int threadId, String data) {
		final body = parseFragment(data.trimRight());
		final List<PostSpan> elements = [];
		int spoilerSpanId = 0;
		for (final node in body.nodes) {
			if (node is dom.Element) {
				if (node.localName == 'br') {
					elements.add(const PostLineBreakSpan());
				}
				else if (node.localName == 'a' && node.attributes['href'] != null) {
					final match = _quoteLinkPattern.firstMatch(node.attributes['href']!);
					if (match != null) {
						elements.add(PostQuoteLinkSpan(
							board: match.group(1)!,
							threadId: int.parse(match.group(2)!),
							postId: int.parse(match.group(3)!)
						));
					}
					else {
						elements.add(PostLinkSpan(node.attributes['href']!, name: node.text.nonEmptyOrNull));
					}
				}
				else if (node.localName == 'span') {
					if (node.classes.contains('greenText')) {
						elements.add(PostQuoteSpan(makeSpan(board, threadId, node.innerHtml)));
					}
					else if (node.classes.contains('redText')) {
						elements.add(PostColorSpan(PostBoldSpan(makeSpan(board, threadId, node.innerHtml)), const Color(0xFFAF0A0F)));
					}
					else if (node.classes.contains('spoiler')) {
						elements.add(PostSpoilerSpan(PostTextSpan(node.text), spoilerSpanId++));
					}
					else {
						elements.add(PostTextSpan(node.text));
					}
				}
				else if (node.localName == 'strong') {
					elements.add(PostBoldSpan(makeSpan(board, threadId, node.innerHtml)));
				}
				else {
					elements.addAll(SiteLainchan.parsePlaintext(node.text));
				}
			}
			else {
				elements.addAll(SiteLainchan.parsePlaintext(node.text ?? ''));
			}
		}
		return PostNodeSpan(elements.toList(growable: false));
	}

	SiteLynxchan({
		required this.name,
		required this.baseUrl,
		required this.boards,
		required this.defaultUsername,
		required super.overrideUserAgent,
		required super.archives,
		required super.imageHeaders,
		required super.videoHeaders,
		required this.hasLinkCookieAuth,
		required this.hasPagedCatalog
	});

	ImageboardFlag? _makeFlag(Map<String, dynamic> data) {
		if (data['flag'] != null) {
			return ImageboardFlag(
				name: data['flagName'],
				imageUrl: Uri.https(baseUrl, data['flag']).toString(),
				imageWidth: 16,
				imageHeight: 11
			);
		}
		else if ((data['flagCode'] as String?)?.startsWith('-') ?? false) {
			return ImageboardFlag(
				name: '',
				imageUrl: Uri.https(baseUrl, '/.static/flags/${data['flagCode'].split('-')[1]}.png').toString(),
				imageWidth: 16,
				imageHeight: 11
			);
		}
		return null;
	}

	@override
	Future<PostReceipt> submitPost(DraftPost post, CaptchaSolution captchaSolution, CancelToken cancelToken) async {
		final password = makeRandomBase64String(8);
		String? fileSha256;
		bool fileAlreadyUploaded = false;
		final file = post.file;
		if (file != null) {
			fileSha256 = sha256.convert(await File(file).readAsBytes()).bytes.map((b) => b.toRadixString(16)).join();
			final filePresentResponse = await client.getUri(Uri.https(baseUrl, '/checkFileIdentifier.js', {
				'json': '1',
				'identifier': fileSha256
			}), cancelToken: cancelToken, options: Options(responseType: ResponseType.json));
			if (filePresentResponse.data case bool x) {
				fileAlreadyUploaded = x;
			}
			else {
				if (filePresentResponse.data['status'] != 'ok') {
					throw PostFailedException('Error checking if file was already uploaded: ${filePresentResponse.data['error'] ?? filePresentResponse.data}');
				}
				fileAlreadyUploaded = filePresentResponse.data['data'] as bool;
			}
		}
		final flag = post.flag;
		final response = await client.postUri(Uri.https(baseUrl, post.threadId == null ? '/newThread.js' : '/replyThread.js', {
			'json': '1'
		}), data: FormData.fromMap({
			if (post.name?.isNotEmpty ?? false) 'name': post.name,
			if (post.options?.isNotEmpty ?? false)'email': post.options,
			'message': post.text,
			'subject': post.subject,
			'password': password,
			'boardUri': post.board,
			if (post.threadId != null) 'threadId': post.threadId.toString(),
			if (captchaSolution is LynxchanCaptchaSolution) ...{
				'captchaId': captchaSolution.id,
				'captcha': captchaSolution.answer
			},
			if (post.spoiler ?? false) 'spoiler': 'spoiler',
			if (flag != null) 'flag': flag.code,
			if (file != null) ...{
				'fileSha256': fileSha256,
				'fileMime': lookupMimeType(file),
				'fileSpoiler': (post.spoiler ?? false) ? 'spoiler': '',
				'fileName': post.overrideFilename ?? file.split('/').last,
				if (!fileAlreadyUploaded) 'files': await MultipartFile.fromFile(file, filename: post.overrideFilename)
			}
		}), options: Options(
			validateStatus: (x) => true,
			extra: {
				kPriority: RequestPriority.interactive
			},
			responseType: null
		), cancelToken: cancelToken);
		if (response.data is String) {
			final document = parse(response.data);
			if (response.statusCode != 200) {
				throw PostFailedException(document.querySelector('#errorLabel')?.text ?? 'HTTP Error ${response.statusCode}');
			}
			final match = RegExp(r'(\d+)\.html#(\d+)?').firstMatch(document.querySelector('#linkRedirect')?.attributes['href'] ?? '');
			if (match != null) {
				return PostReceipt(
					post: post,
					id: match.group(2) != null ? int.parse(match.group(2)!) : int.parse(match.group(1)!),
					password: password,
					name: post.name ?? '',
					options: post.options ?? '',
					time: DateTime.now(),
					ip: captchaSolution.ip
				);
			}
			throw PostFailedException(document.querySelector('title')?.text ?? 'Unknown error');
		}
		if (response.data['status'] != 'ok') {
			throw PostFailedException(response.data['error'] ?? response.data.toString());
		}
		return PostReceipt(
			id: response.data['data'],
			password: password,
			name: post.name ?? '',
			options: post.options ?? '',
			time: DateTime.now(),
			post: post,
			ip: captchaSolution.ip
		);
	}

	@override
	Future<BoardThreadOrPostIdentifier?> decodeUrl(String url) async {
		return SiteLainchan.decodeGenericUrl(baseUrl, 'res', url);
	}

	@override
	Future<void> deletePost(ThreadIdentifier thread, PostReceipt receipt, CaptchaSolution captchaSolution, CancelToken cancelToken, {required bool imageOnly}) async {
		final response = await client.postUri(Uri.https(baseUrl, '/contentActions.js', {
			'json': '1'
		}), data: {
			'action': 'delete',
			'password': receipt.password,
			'confirmation': 'true',
			'meta-${thread.id}-${receipt.id}': 'true',
			if (imageOnly) 'deleteUploads': 'true'
		}, options: Options(
			extra: {
				kPriority: RequestPriority.interactive
			},
			responseType: ResponseType.json
		), cancelToken: cancelToken);
		if (response.data['status'] != 'ok') {
			throw DeletionFailedException(response.data['data'] ?? response.data);
		}
	}

	@override
	Future<List<ImageboardBoard>> getBoards({required RequestPriority priority, CancelToken? cancelToken}) async {
		if (boards != null) {
			return boards!;
		}
		final response = await client.getUri(Uri.https(baseUrl, '/boards.js'), options: Options(
			responseType: ResponseType.plain,
			extra: {
				kPriority: priority
			}
		), cancelToken: cancelToken);
		return _getBoardsFromResponse(response);
	}

	List<ImageboardBoard> _getBoardsFromResponse(Response response) {
		final document = parse(response.data);
		final list = <ImageboardBoard>[];
		final linkPattern = RegExp(r'^\/([^/]+)\/ - (.*)$');
		for (final cell in document.querySelectorAll('#divBoards .boardsCell')) {
			final col1 = cell.querySelector('span');
			final match = linkPattern.firstMatch(col1?.querySelector('.linkBoard')?.text ?? '');
			if (col1 == null || match == null) {
				continue;
			}
			list.add(ImageboardBoard(
				name: match.group(1)!,
				title: match.group(2)!,
				isWorksafe: col1.querySelector('.indicatorSfw') != null,
				webmAudioAllowed: true,
				popularity: int.tryParse(cell.querySelector('.labelPostCount')?.text ?? '')
			));
		}
		if (list.isEmpty) {
			for (final cell in document.querySelectorAll('#divBoards tr')) {
				final col1 = cell.querySelector('td');
				final match = linkPattern.firstMatch(col1?.querySelector('.linkBoard')?.text ?? '');
				if (col1 == null || match == null) {
					continue;
				}
				list.add(ImageboardBoard(
					name: match.group(1)!,
					title: match.group(2)!,
					isWorksafe: col1.querySelector('.indicatorSfw') != null,
					webmAudioAllowed: true,
					popularity: int.tryParse(cell.querySelector('.labelPostCount')?.text ?? '')
				));
			}
		}
		return list;
	}

	@override
	ImageboardBoardPopularityType? get boardPopularityType => ImageboardBoardPopularityType.postsCount;

	@override
	Future<List<ImageboardBoard>> getBoardsForQuery(String query) async {
		final response = await client.getUri(Uri.https(baseUrl, '/boards.js', {
			'boardUri': query
		}), options: Options(
			responseType: ResponseType.plain,
			extra: {
				kPriority: RequestPriority.functional
			}
		));
		return _getBoardsFromResponse(response);
	}

	@override
	Future<CaptchaRequest> getCaptchaRequest(String board, int? threadId, {CancelToken? cancelToken}) async {
		final captchaMode = persistence?.maybeGetBoard(board)?.captchaMode ?? 0;
		if (captchaMode == 0 ||
				(captchaMode == 1 && threadId != null)) {
			return const NoCaptchaRequest();
		}
		return LynxchanCaptchaRequest(
			board: board
		);
	}

	void _updateBoardInformation(String boardName, Map<String, dynamic> data) {
		try {
			final board = (persistence?.maybeGetBoard(boardName))!;
			board.maxCommentCharacters = data['maxMessageLength'] as int?;
			final fileSizeParts = (data['maxFileSize'] as String).split(' ');
			double maxFileSize = double.parse(fileSizeParts.first);
			if (fileSizeParts[1].toLowerCase().startsWith('m')) {
				maxFileSize *= 1024 * 1024;
			}
			else if (fileSizeParts[1].toLowerCase().startsWith('k')) {
				maxFileSize *= 1024;
			}
			else {
				throw Exception('Unexpected file-size unit: ${fileSizeParts[1]}');
			}
			board.captchaMode = data['captchaMode'] as int?;
			board.maxImageSizeBytes = maxFileSize.round();
			board.maxWebmSizeBytes = maxFileSize.round();
			board.pageCount = data['pageCount'] as int?;
			board.additionalDataTime = DateTime.now();
		}
		catch (e, st) {
			print(e);
			print(st);
		}
	}

	Future<void> _maybeUpdateBoardInformation(String boardName) async {
		final board = persistence?.maybeGetBoard(boardName);
		if (board?.popularity != null && DateTime.now().difference(board?.additionalDataTime ?? DateTime(2000)) > const Duration(days: 3)) {
			// Not updated recently
			return;
		}
		final response = await client.getUri(Uri.https(baseUrl, '/$boardName/1.json'));
		_updateBoardInformation(boardName, response.data);
	}

	Future<List<Thread>> _getCatalogPage(String board, int page, {required RequestPriority priority, CancelToken? cancelToken}) async {
		final response = await client.getUri(Uri.https(baseUrl, '/$board/$page.json'), options: Options(
			validateStatus: (status) => status == 200 || status == 404,
			extra: {
				kPriority: priority
			},
			responseType: ResponseType.json
		), cancelToken: cancelToken);
		if (response.statusCode == 404) {
			throw BoardNotFoundException(board);
		}
		_updateBoardInformation(board, response.data);
		return (response.data['threads'] as List).cast<Map>().map(wrapUnsafe((o) => _makeThreadFromCatalog(board, o.cast<String, dynamic>())..currentPage = page)).toList();
	}

	static int? _tryParseInt(dynamic s) => switch (s) {
		int x => x,
		String x => int.tryParse(x),
		_ => null
	};

	Thread _makeThreadFromCatalog(String board, Map<String, dynamic> obj) {
		final op = Post(
			board: board,
			text: obj['markdown'],
			name: obj['name'] ?? defaultUsername,
			flag: wrapUnsafe(_makeFlag)(obj),
			capcode: obj['signedRole'],
			time: DateTime.parse(obj['creation']),
			threadId: obj['threadId'],
			id: obj['threadId'],
			spanFormat: PostSpanFormat.lynxchan,
			attachments_: (obj['files'] as List?)?.map((f) => Attachment(
				type: AttachmentType.fromFilename(f['path']),
				board: board,
				id: f['path'],
				ext: '.${(f['path'] as String).split('.').last}',
				filename: f['originalName'] ?? (f['path'] as String).split('/').last,
				url: Uri.https(imageUrl, f['path']).toString(),
				thumbnailUrl: Uri.https(imageUrl, f['thumb']).toString(),
				md5: '',
				width: _tryParseInt(f['width']),
				height: _tryParseInt(f['height']),
				threadId: obj['threadId'],
				sizeInBytes: f['size']
			)).toList() ?? const []
		);
		return Thread(
			posts_: [op],
			replyCount: obj['postCount'] ?? ((obj['omittedPosts'] ?? obj['ommitedPosts'] ?? 0) + ((obj['posts'] as List?)?.length ?? 0)),
			imageCount: obj['fileCount'] ?? ((obj['omittedFiles'] ?? 0) + ((obj['posts'] as List?)?.fold<int>(0, (c, p) => c + (p['files'] as List).length) ?? 0)),
			id: op.id,
			board: board,
			title: (obj['subject'] as String?)?.unescapeHtml,
			isSticky: obj['pinned'],
			time: DateTime.parse(obj['creation']),
			attachments: op.attachments_,
			currentPage: obj['page']
		);
	}


	@override
	Future<List<Thread>> getCatalogImpl(String board, {CatalogVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		if (hasPagedCatalog) {
			return await _getCatalogPage(board, 1, priority: priority, cancelToken: cancelToken);
		}
		final response = await client.getUri(Uri.https(baseUrl, '/$board/catalog.json'), options: Options(
			validateStatus: (status) => status == 200 || status == 404,
			extra: {
				kPriority: priority
			}
		), cancelToken: cancelToken);
		if (response.statusCode == 404) {
			throw BoardNotFoundException(board);
		}
		_maybeUpdateBoardInformation(board); // Don't await
		return (response.data as List).cast<Map>().map((o) => _makeThreadFromCatalog(board, o.cast<String, dynamic>())).toList();
	}

	/// catalog.json may be missing important details, but always has threadId + page
	@override
	Future<Map<int, int>> getCatalogPageMapImpl(String board, {CatalogVariant? variant, required RequestPriority priority, DateTime? acceptCachedAfter, CancelToken? cancelToken}) async {
		final response = await client.getUri(Uri.https(baseUrl, '/$board/catalog.json'), options: Options(
			validateStatus: (status) => status == 200 || status == 404,
			extra: {
				kPriority: priority
			}
		), cancelToken: cancelToken);
		if (response.statusCode == 404) {
			throw BoardNotFoundException(board);
		}
		return {
			for (final obj in (response.data as List).cast<Map>())
				obj['threadId'] as int: obj['page'] as int
		};
	}

	@override
	Future<List<Thread>> getMoreCatalogImpl(String board, Thread after, {CatalogVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		try {
			return _getCatalogPage(board, (after.currentPage ?? 0) + 1, priority: priority, cancelToken: cancelToken);
		}
		on BoardNotFoundException {
			return [];
		}
	}

	Post _makePost(String board, int threadId, int id, Map<String, dynamic> obj) => unsafe(obj, () {
		return Post(
			board: board,
			text: obj['markdown'],
			name: obj['name'],
			flag: wrapUnsafe(_makeFlag)(obj),
			capcode: obj['signedRole'],
			time: DateTime.parse(obj['creation']),
			threadId: threadId,
			posterId: obj['id'],
			id: id,
			spanFormat: PostSpanFormat.lynxchan,
			attachments_: (obj['files'] as List).asMap().entries.map(wrapUnsafe((e) => Attachment(
				type: AttachmentType.fromFilename(e.value['path']),
				board: board,
				// Lynxchan dedupes images. Prepend some uniqueness here to avoid Hero problems later.
				id: '$id-${e.key}-${e.value['path']}',
				ext: '.${(e.value['path'] as String).split('.').last}',
				filename: e.value['originalName'],
				url: Uri.https(imageUrl, e.value['path']).toString(),
				thumbnailUrl: Uri.https(imageUrl, e.value['thumb']).toString(),
				md5: '',
				width: _tryParseInt(e.value['width']),
				height: _tryParseInt(e.value['height']),
				threadId: obj['threadId'],
				sizeInBytes: e.value['size']
			))).toList()
		);
	});

	@override
	Future<Thread> makeThread(ThreadIdentifier thread, Response<dynamic> response, {
		required RequestPriority priority,
		CancelToken? cancelToken
	}) async {
		_maybeUpdateBoardInformation(thread.board); // Don't await
		final op = _makePost(thread.board, thread.id, thread.id, response.data);
		final posts = [
			op,
			...(response.data['posts'] as List).map((obj) => _makePost(thread.board, thread.id, obj['postId'], obj))
		];
		return Thread(
			posts_: posts,
			replyCount: posts.length - 1,
			imageCount: posts.fold<int>(0, (c, p) => c + p.attachments.length) - op.attachments.length,
			id: thread.id,
			board: thread.board,
			title: (response.data['subject'] as String?)?.unescapeHtml,
			isSticky: response.data['pinned'],
			time: op.time,
			attachments: op.attachments_,
			isArchived: response.data['archived'] ?? false
		);
	}

	@override
	RequestOptions getThreadRequest(ThreadIdentifier thread, {ThreadVariant? variant})
		=> RequestOptions(
			path: '/${thread.board}/res/${thread.id}.json',
			baseUrl: 'https://$baseUrl',
			responseType: ResponseType.json
		);

	@override
	String getWebUrlImpl(String board, [int? threadId, int? postId]) {
		String url = 'https://$baseUrl/$board/';
		if (threadId != null) {
			url += 'res/$threadId.html';
			if (postId != null) {
				url += '#$postId';
			}
		}
		return url;
	}

	@override
	Uri? get iconUrl => Uri.https(baseUrl, '/favicon.ico');

	@override
	List<ImageboardSnippet> getBoardSnippets(String board) => const [
		greentextSnippet
	];

	@override
	String get siteData => baseUrl;

	@override
	String get siteType => 'lynxchan';

	@override
	final bool hasPagedCatalog;

	@override
	Future<void> clearPseudoCookies() async {
		persistence?.browserState.loginFields.remove(kLoginFieldLastSolvedCaptchaKey);
	}

	static const kLoginFieldLastSolvedCaptchaKey = 'lc';

	@override
	/// All images hosted in baseUrl anyway
	String get imageUrl => baseUrl;

	@override
	bool operator == (Object other) =>
		identical(other, this) ||
		other is SiteLynxchan &&
		other.name == name &&
		other.baseUrl == baseUrl &&
		listEquals(other.boards, boards) &&
		other.defaultUsername == defaultUsername &&
		other.hasLinkCookieAuth == hasLinkCookieAuth &&
		other.hasPagedCatalog == hasPagedCatalog &&
		super==(other);
	
	@override
	int get hashCode => baseUrl.hashCode;
}