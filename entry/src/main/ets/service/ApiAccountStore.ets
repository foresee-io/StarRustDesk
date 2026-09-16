import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { RustDeskNapi } from './RustDeskNapi';

export interface ApiSession {
  server: string;
  provider: string;
  token: string;
  username: string;
  allowHttp: boolean;
  boundRendezvous?: string;
  boundKey?: string;
}
interface SessionManifest { parts: number; }

// Separate namespace, never enumerated by connection backup/cloud-sync code.
export class ApiAccountStore {
  private static pending: Promise<void> = Promise.resolve();
  private static enqueue(operation: () => Promise<void>): Promise<void> {
    const result = ApiAccountStore.pending.then(operation, operation);
    ApiAccountStore.pending = result.catch(() => {});
    return result;
  }
  private static alias(part: number = -1): Uint8Array {
    return new util.TextEncoder().encodeInto('starrustdesk.api.account.v1' + (part < 0 ? '' : `.part.${part}`));
  }
  private static async readSecret(part: number = -1): Promise<Uint8Array> {
    let query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, ApiAccountStore.alias(part));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    const results = await asset.query(query);
    if (results.length !== 1) throw new Error('Account asset unavailable');
    return results[0].get(asset.Tag.SECRET) as Uint8Array;
  }
  private static async addSecret(bytes: Uint8Array, part: number = -1): Promise<void> {
    let attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, ApiAccountStore.alias(part));
    attributes.set(asset.Tag.SECRET, bytes);
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    await asset.add(attributes);
  }
  static clear(): Promise<void> {
    return ApiAccountStore.enqueue(() => ApiAccountStore.removeStored());
  }
  private static async removeStored(): Promise<void> {
    // Persist a non-secret tombstone even if AssetStore removal fails.
    RustDeskNapi.setOption('api-session-disabled', '1');
    for (let part = -1; part < 32; part++) {
      let query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, ApiAccountStore.alias(part));
      try { await asset.remove(query); } catch (_e) {}
    }
  }
  static save(session: ApiSession): Promise<void> {
    return ApiAccountStore.enqueue(() => ApiAccountStore.writeStored(session));
  }
  private static async writeStored(session: ApiSession): Promise<void> {
    await ApiAccountStore.removeStored();
    const bytes = new util.TextEncoder().encodeInto(JSON.stringify(session));
    if (bytes.length > 32768) throw new Error('Account session too large');
    // AssetStore SECRET is limited to 1024 bytes. Publish the manifest last.
    const parts = Math.ceil(bytes.length / 1024);
    for (let part = 0; part < parts; part++) {
      await ApiAccountStore.addSecret(bytes.slice(part * 1024, (part + 1) * 1024), part);
    }
    const manifest: SessionManifest = { parts: parts };
    await ApiAccountStore.addSecret(new util.TextEncoder().encodeInto(JSON.stringify(manifest)));
    RustDeskNapi.setOption('api-session-disabled', '0');
  }
  static async load(): Promise<ApiSession | undefined> {
    await ApiAccountStore.pending;
    if (RustDeskNapi.getOption('api-session-disabled') === '1') return undefined;
    try {
      const manifest: SessionManifest = JSON.parse(util.TextDecoder.create('utf-8')
        .decodeToString(await ApiAccountStore.readSecret())) as SessionManifest;
      if (!Number.isInteger(manifest.parts) || manifest.parts < 1 || manifest.parts > 32) return undefined;
      const buffer = new Uint8Array(32768);
      let size = 0;
      for (let part = 0; part < manifest.parts; part++) {
        const bytes = await ApiAccountStore.readSecret(part);
        if (bytes.length === 0 || bytes.length > 1024) return undefined;
        buffer.set(bytes, size); size += bytes.length;
      }
      const raw = util.TextDecoder.create('utf-8').decodeToString(buffer.slice(0, size));
      const session: ApiSession = JSON.parse(raw) as ApiSession;
      if (typeof session.server !== 'string' || typeof session.token !== 'string' ||
        typeof session.username !== 'string' || !['official', 'thirdParty'].includes(session.provider) ||
        session.token.length === 0 || session.token.length > 16384) return undefined;
      return session;
    } catch (_e) { return undefined; }
  }
}
