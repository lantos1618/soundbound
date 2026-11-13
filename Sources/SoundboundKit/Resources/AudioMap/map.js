// Soundbound audio map. The app pushes a snapshot through window.updateMap(); this file only draws it.
// Cards can be dragged; boundaries follow them. Built on React Flow (reactflow 11): pan, zoom, drag and fit-to-view come from the library.
(function () {
  const h = React.createElement;
  const RF = window.ReactFlow;
  const Flow = RF.default || RF.ReactFlow;
  const { Background, Controls, Handle, Position, MarkerType, applyNodeChanges } = RF;
  const COLUMN = 330, ROW = 290, NODE_WIDTH = 240, NODE_HEIGHT = 180;
  // Space between a boundary and the cards inside it. A device box sits outside the Soundbound box, so it gets more.
  const PAD = { device: 44, app: 18, network: 18 };
  const LABEL = { device: 34, app: 26, network: 26 };

  function Spark(props) {
    const bars = props.level.length ? props.level : new Array(24).fill(0);
    return h('div', { className: 'spark' + (window.mapMeter === 'frequency' ? ' freq' : ''), 'aria-label': window.mapMeter === 'frequency' ? 'Frequencies' : 'Level' },
      bars.map((value, index) => h('i', { key: index, style: { height: Math.max(2, Math.min(1, value) * 26) + 'px' } })));
  }

  function send(id, value) {
    const handlers = window.webkit && window.webkit.messageHandlers;
    if (handlers && handlers.control) handlers.control.postMessage({ id: id, value: value });
  }
  // A slider keeps its own value while it is held, so the app's quarter-second updates never fight the drag.
  function Slider(props) {
    const control = props.control;
    const [value, setValue] = React.useState(control.value);
    const held = React.useRef(false);
    React.useEffect(function () { if (!held.current) setValue(control.value); }, [control.value]);
    return h('label', { className: 'control nodrag nopan' },
      h('span', null, control.label),
      h('input', { type: 'range', min: control.min, max: control.max, step: 1, value: value,
        onPointerDown: function () { held.current = true; },
        onPointerUp: function () { held.current = false; }, onBlur: function () { held.current = false; },
        onChange: function (event) { const next = Number(event.target.value); setValue(next); send(control.id, next); } }),
      h('b', null, control.stops ? control.stops[value] : value + ' ' + control.unit),
      // Fixed stops get tick marks, with the default one picked out.
      control.stops ? h('div', { className: 'ticks' }, control.stops.map(function (name, index) {
        return h('i', { key: index, className: name === '1 ms' ? 'default' : '', title: name }); })) : null);
  }
  function ControlRow(props) {
    const control = props.control;
    if (control.kind === 'slider') return h(Slider, { control: control });
    return h('button', { className: 'action nodrag nopan', disabled: control.disabled,
      onClick: function (event) { event.stopPropagation(); send(control.id, 0); } }, control.label);
  }

  function MapNode(props) {
    const data = props.data;
    const classes = 'node' + (data.active ? ' active' : '') + (props.selected ? ' selected' : '');
    return h('div', { className: classes },
      data.kind !== 'source' ? h(Handle, { type: 'target', position: Position.Left }) : null,
      h('div', { className: 'stage' }, data.stage),
      h('div', { className: 'head' },
        h('span', { className: 'dot' }),
        h('div', null, h('div', { className: 'title' }, data.title), h('div', { className: 'sub' }, data.subtitle))),
      data.level ? h(Spark, { level: data.level }) : null,
      data.metrics.length ? h('table', { className: 'metrics' }, h('tbody', null,
        data.metrics.map((row, index) => h('tr', { key: index },
          h('td', null, row.label), h('td', { className: 'v ' + (row.tone || '') }, row.value))))) : null,
      data.controls && data.controls.length ? h('div', { className: 'controls' },
        data.controls.map(function (control) { return h(ControlRow, { key: control.id, control: control }); })) : null,
      data.total ? h('div', { className: 'total' + (data.active ? '' : ' idle') },
        data.total.label + ' ', h('b', null, data.total.value)) : null,
      data.kind !== 'output' ? h(Handle, { type: 'source', position: Position.Right }) : null,
      // Sound arriving from the network enters on the network side, lower down so it clears the outgoing line.
      // Lines to and from the network run vertically, so every card also has unobtrusive top and bottom points.
      h(Handle, { type: 'source', position: Position.Top, id: 's-top' }), h(Handle, { type: 'source', position: Position.Bottom, id: 's-bottom' }),
      h(Handle, { type: 'target', position: Position.Top, id: 't-top' }), h(Handle, { type: 'target', position: Position.Bottom, id: 't-bottom' }));
  }
  // A boundary: a device, the Soundbound app running inside it, or the network between devices.
  function Region(props) {
    return h('div', { className: 'region ' + props.data.kind }, h('span', null, props.data.label));
  }
  // Bounds come from the member cards' real, measured frames. Until a card has been measured,
  // its nominal size stands in, and the box is redrawn as soon as the measurement arrives.
  function regionNode(region, cards) {
    const members = cards.filter(function (card) { return region.members.indexOf(card.id) >= 0; });
    if (!members.length) return null;
    let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
    members.forEach(function (card) {
      left = Math.min(left, card.position.x); top = Math.min(top, card.position.y);
      right = Math.max(right, card.position.x + (card.width || NODE_WIDTH));
      bottom = Math.max(bottom, card.position.y + (card.height || NODE_HEIGHT));
    });
    const pad = PAD[region.kind], label = LABEL[region.kind];
    return {
      id: region.id, type: 'region', data: region, draggable: false, selectable: false, zIndex: -1,
      position: { x: left - pad, y: top - pad - label },
      // The size is known, so say so: a node without one is hidden until the library has measured it,
      // which made boundaries blink on every update.
      width: right - left + 2 * pad, height: bottom - top + 2 * pad + label,
      style: { width: right - left + 2 * pad, height: bottom - top + 2 * pad + label }
    };
  }
  const nodeTypes = { map: MapNode, region: Region };

  function App() {
    const [nodes, setNodes] = React.useState([]);
    const [edges, setEdges] = React.useState([]);
    const [regions, setRegions] = React.useState([]);
    const [selected, setSelected] = React.useState(null);
    const [empty, setEmpty] = React.useState('Waiting for the app…');
    const moved = React.useRef({});
    const chosen = React.useRef(null);
    const flow = React.useRef(null);
    const shape = React.useRef('');

    React.useEffect(function () {
      window.updateMap = function (snapshot) {
        window.mapMeter = snapshot.meter;
        setEmpty(snapshot.nodes.length ? '' : snapshot.empty);
        setRegions(snapshot.regions);
        setNodes(function (previous) {
          const known = {};
          previous.forEach(function (card) { known[card.id] = card; });
          return snapshot.nodes.map(function (node) {
            const before = known[node.id] || {};
            // Keep the measured size across updates; the library reports it only when it changes.
            return { id: node.id, type: 'map', data: node, selected: node.id === chosen.current, zIndex: 1,
                     width: before.width, height: before.height,
                     position: moved.current[node.id] || { x: node.column * COLUMN, y: node.row * ROW } };
          });
        });
        setEdges(snapshot.edges.map(function (edge) {
          return { id: edge.id, source: edge.from, target: edge.to, label: edge.label || undefined,
                   markerStart: edge.both ? { type: MarkerType.ArrowClosed } : undefined,
                   sourceHandle: edge.fromSide ? 's-' + edge.fromSide : undefined, targetHandle: edge.toSide ? 't-' + edge.toSide : undefined,
                   animated: edge.active, className: edge.active ? 'live' : '',
                   labelBgPadding: [6, 3], labelBgBorderRadius: 6,
                   markerEnd: { type: MarkerType.ArrowClosed } };
        }));
        // Re-frame only when the set of nodes changes, so live updates never fight the viewer's pan and zoom.
        const signature = snapshot.nodes.map(function (node) { return node.id; }).join('|');
        if (signature !== shape.current) {
          shape.current = signature; moved.current = {};
          setTimeout(function () { if (flow.current) flow.current.fitView({ padding: 0.12, duration: 250 }); }, 60);
        }
      };
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ready) {
        window.webkit.messageHandlers.ready.postMessage('ready');
      }
    }, []);

    const onNodesChange = React.useCallback(function (changes) {
      changes.forEach(function (change) {
        if (change.type === 'position' && change.position) moved.current[change.id] = change.position;
      });
      setNodes(function (current) { return applyNodeChanges(changes, current); });
    }, []);
    const pick = function (id) { chosen.current = id; setSelected(id); };
    const drawn = React.useMemo(function () {
      return regions.map(function (region) { return regionNode(region, nodes); })
        .filter(Boolean).concat(nodes);
    }, [regions, nodes]);

    return h(React.Fragment, null,
      h('div', { className: 'flow', style: { position: 'relative' } },
        h(Flow, {
          nodes: drawn, edges: edges, nodeTypes: nodeTypes, onNodesChange: onNodesChange,
          onInit: function (instance) { flow.current = instance; },
          nodesConnectable: false, nodesDraggable: true, elementsSelectable: false, minZoom: 0.15, maxZoom: 1.6,
          proOptions: { hideAttribution: true }
        },
          h(Background, { gap: 22, size: 1 }),
          h(Controls, { showInteractive: false })),
        Object.keys(moved.current).length ? h('button', { className: 'tidy', onClick: function () {
          moved.current = {};
          setNodes(function (current) { return current.map(function (card) {
            return Object.assign({}, card, { position: { x: card.data.column * COLUMN, y: card.data.row * ROW } }); }); });
        } }, 'Tidy up') : null,
        empty ? h('div', { className: 'empty' }, empty) : null));
  }

  ReactDOM.createRoot(document.getElementById('root')).render(h(App));
})();
