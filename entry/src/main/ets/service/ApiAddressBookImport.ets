import { util } from '@kit.ArkTS';
import { ApiBook, ApiPeer, ApiFailure } from './RustDeskApiService';
import { RustDeskNapi } from './RustDeskNapi';
import { CloudSyncService } from './CloudSyncService';

interface SavedGroup { id: string; name: string; expanded: boolean; }
export class ApiAddressBookImport {
  static importSelected(book: ApiBook, peers: ApiPeer[]): number {
    if (peers.length === 0) throw new ApiFailure('请先选择要导入的设备');
    const oldRows = RustDeskNapi.getOption('saved-connections');
    const oldGroups = RustDeskNapi.getOption('saved-connection-groups');
    let rows: Record<string, string>[];
    let groups: SavedGroup[];
    try {
      rows = JSON.parse(oldRows || '[]') as Record<string, string>[];
      groups = JSON.parse(oldGroups || '[]') as SavedGroup[];
      if (!Array.isArray(rows) || !Array.isArray(groups) || rows.some((row: Record<string, string>) =>
        !row || typeof row.remoteId !== 'string')) throw new Error('invalid');
    } catch (_e) { throw new ApiFailure('本地连接数据异常，已取消导入，未覆盖原数据'); }
    const groupId = `api-${util.generateRandomUUID(true)}`;
    let added = 0;
    for (const peer of peers) {
      if (rows.some((row: Record<string, string>) => row.remoteId === peer.id)) continue;
      const id = `api-peer-${util.generateRandomUUID(true)}`;
      const newRow: Record<string, string> = {};
      newRow['id'] = id;
      newRow['name'] = peer.name;
      newRow['remoteId'] = peer.id;
      newRow['credentialAlias'] = id;
      newRow['performancePreset'] = 'smooth';
      newRow['groupId'] = groupId;
      rows.push(newRow);
      added++;
    }
    if (added === 0) return 0;
    groups.push({ id: groupId, name: `地址簿 · ${book.name}`.slice(0, 80), expanded: true });
    RustDeskNapi.setOption('saved-connection-groups', JSON.stringify(groups));
    RustDeskNapi.setOption('saved-connections', JSON.stringify(rows));
    CloudSyncService.markLocalChanged();
    AppStorage.setOrCreate('savedConnectionsCloudRevision',
      (AppStorage.get<number>('savedConnectionsCloudRevision') ?? 0) + 1);
    return added;
  }
}
