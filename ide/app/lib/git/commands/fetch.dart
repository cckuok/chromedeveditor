// Copyright (c) 2014, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library git.commands.fetch;

import 'dart:async';
import 'dart:typed_data';

import 'package:chrome/chrome_app.dart' as chrome;

import '../constants.dart';
import '../exception.dart';
import '../fast_sha.dart';
import '../file_operations.dart';
import '../http_fetcher.dart';
import '../object.dart';
import '../objectstore.dart';
import '../options.dart';
import '../pack.dart';
import '../pack_index.dart';
import '../upload_pack_parser.dart';
import '../utils.dart';
import 'status.dart';

/**
 * A git fetch command implementation.
 *
 * TODO add unittests.
*/

class Fetch {

  GitOptions options;
  chrome.DirectoryEntry root;
  ObjectStore store;
  Function progress;
  String branchName;

  Fetch(this.options){
    root = options.root;
    store = options.store;
    progress = options.progressCallback;
    branchName = options.branchName == null ? 'master' : options.branchName;

    if (progress == null) progress = nopFunction;
  }

   Future fetch() {
    String username = options.username;
    String password = options.password;

    Function fetchProgress;
    // TODO add fetchProgress chunker.

    return Status.isWorkingTreeClean(store).then((_) {
      String url = store.config.url;

      HttpFetcher fetcher = new HttpFetcher(store, 'origin', url, username,
          password);

      // get current branch.
      String headRefName = 'refs/heads/' + branchName;
      return fetcher.fetchUploadRefs().then((List<GitRef> refs) {
        GitRef branchRef = refs.firstWhere((GitRef ref) =>
            ref.name == headRefName);

        if (branchRef != null) {
          // see if we know about the branch's head commit. If so we're up to
          // date. If not, request from remote.
          return store.getRemoteHeadForRef(headRefName).then((sha) {
            if (sha == branchRef.sha) {
              return store.getCommitGraph([sha]).then((CommitGraph graph) {
                if (graph.commits.isNotEmpty) {
                  throw new GitException(GitErrorConstants.GIT_BRANCH_UPTO_DATE);
                } else {
                  return _handleFetch(branchRef, branchRef, fetcher);
                }
              });
            } else {
              return _handleFetch(branchRef, branchRef, fetcher);
            }
          });
        } else {
          return new GitException(
              GitErrorConstants.GIT_REMOTE_BRANCH_NOT_FOUND);
        }
      });
    }, onError: (e) {
      throw new GitException(GitErrorConstants.GIT_BRANCH_NOT_FOUND);
    });
  }

  /**
   * Create pack and packIndex file. Returns objects directory.
   */
  Future<chrome.DirectoryEntry> _createPackFiles(String packName,
      ByteBuffer packBuffer, ByteBuffer packIdxBuffer) {
    return FileOps.createDirectoryRecursive(root, '.git/objects').then(
        (chrome.DirectoryEntry objectsDir) {
      return FileOps.createFileWithContent(objectsDir, 'pack/${packName}.pack',
          packBuffer, 'blob').then((_) {
        return FileOps.createFileWithContent(objectsDir, 'pack/${packName}.idx',
            packIdxBuffer, 'blob').then((_) {
          return new Future.value(objectsDir);
        });
      });
    });
  }

  Future _createAndUpdateRef(GitRef branchRef, GitRef wantRef) {
    String path = '.git/' + REFS_REMOTE_HEADS + branchRef.name.split('/').last;
    return FileOps.createFileWithContent(root, path, branchRef.sha, "Text");
  }

  Future _handleFetch(GitRef branchRef, GitRef wantRef, HttpFetcher fetcher) {

    // Get the sha from the ref name.
    return store.getRemoteHeadForRef(branchRef.name).then((String sha) {
      branchRef.localHead = sha;
      return store.getCommitGraph([sha], 32).then((CommitGraph graph) {
        List<String> haveRefs = graph.commits.map((CommitObject commit)
            => commit.treeSha).toList();
        if (haveRefs.isEmpty) {
          haveRefs = null;
        }
        return fetcher.fetchRef([wantRef.sha], haveRefs, store.config.shallow,
            null, graph.nextLevel, null, progress).then((PackParseResult result) {
          List<int> packSha = result.data.sublist(result.data.length - 20);
          Uint8List packIdxData = PackIndex.writePackIndex(result.objects,
              packSha);

          // Get a veiw of the sorted shas.
          int offset = 4 + 4 + (256 * 4);
          Uint8List sortedShas = packIdxData.sublist(offset,
              offset + result.objects.length * 20);

          FastSha sha1 = new FastSha();
          sha1.add(sortedShas);
          String packNameSha = shaBytesToString(sha1.close());

          String packName = 'pack-${packNameSha}';

          return _createPackFiles(packName, result.data.buffer,
              packIdxData.buffer).then((objectsDir) {
            store.objectDir = objectsDir;
            PackIndex packIdx = new PackIndex(packIdxData);
            store.packs.add(new PackEntry(new Pack(result.data, store), packIdx));
            return _createAndUpdateRef(branchRef, wantRef);
          });
        });
      });
    });
  }
}
