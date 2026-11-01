import * as api from './primary.ms';
import { Base } from './base.jms';
import type { PublicTag } from './primary.ms';
import { marker } from './marker.js';

declare const HOST_DEFINE: string;
declare global {
  namespace JSX {
    interface IntrinsicElements { panel: { value: number }; }
    interface Element { tag: string; value: number; }
  }
}
function makeElement(tag: string, props: { value: number }): JSX.Element {
  return { tag, value: props.value };
}
export const child = new api.Child(4);
const base: Base = child;
const tag: PublicTag = { label: 'typed' };
export const element = <panel value={child.doubled()} />;
export const snapshot = {
  value: base.add(api.increment(2)),
  doubled: child.doubled(),
  answer: api.answer,
  label: api.readLabel({ text: tag.label }),
  nominal: child instanceof Base,
  typeOnlyAbsent: !('PublicTag' in api),
  marker,
  define: HOST_DEFINE,
};
