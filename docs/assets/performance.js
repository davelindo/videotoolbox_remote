/* The charts and exact values share one measured dataset. */
(() => {
  const container = document.querySelector('#benchmark');
  const source = document.querySelector('#benchmark-data');
  if (!container || !source || !window.Chart) return;

  const data = JSON.parse(source.textContent);
  const controls = ['input', 'codec', 'size'].map(name => document.querySelector(`#benchmark-${name}`));
  const pipelines = {
    'intel-vaapi': { label: 'Intel VA-API', color: '#a4c8ff' },
    'cpu-fast': { label: 'CPU fast', color: '#b1b6be' },
    'cpu-medium': { label: 'CPU medium', color: '#d9b98f' },
    'videotoolbox': { label: 'VT local', color: '#c7b9f2' },
    'videotoolbox-remote': { label: 'VT remote', color: '#a6efc3' },
    'nvenc-p4': { label: 'NVENC P4', color: '#76b900' },
    'nvenc-p7': { label: 'NVENC P7', color: '#c1db82' },
  };
  const formatter = new Intl.NumberFormat('en', { maximumFractionDigits: 2 });
  const charts = [];
  let selected = [];
  let energySelected = [];

  const metrics = [
    { id: 'speed', key: 'median_fps', unit: 'fps', title: 'Frames per second',
      detail: row => [`Run range: ${formatter.format(row.min_fps)}–${formatter.format(row.max_fps)} fps`, `${formatter.format(row.median_fps / 30)}× real time`] },
    { id: 'quality', key: 'vmaf', unit: 'VMAF', title: 'VMAF score', max: 100,
      detail: row => [`Scored file: ${formatter.format(row.scored_output.container_mbps)} Mb/s`, `SSIM: ${row.ssim.toFixed(6)}`] },
    { id: 'cpu', key: 'median_cpu_seconds', unit: 'CPU s', title: 'FFmpeg CPU seconds',
      detail: row => [row.backend === 'videotoolbox-remote' ? 'Linux client FFmpeg process' : 'Local FFmpeg process'] },
    { id: 'energy', key: 'median_joules', unit: 'J', title: 'Mac-system / GPU-board joules',
      detail: row => [`${row.power_scope}: ${formatter.format(row.average_watts)} W`, `${formatter.format(row.frames_per_joule)} frames/J`] },
  ];

  for (const metric of metrics) {
    const metricRows = () => metric.id === 'energy' ? energySelected : selected;
    charts.push(new Chart(document.querySelector(`#benchmark-${metric.id}`), {
      type: 'bar',
      data: { labels: [], datasets: [{ data: [], backgroundColor: [], borderRadius: 4, barThickness: 22 }] },
      options: {
        indexAxis: 'y', responsive: true, maintainAspectRatio: false, animation: false,
        layout: { padding: { right: 14 } },
        scales: {
          x: { beginAtZero: true, max: metric.max, grid: { color: '#30343a' },
            ticks: { color: '#9299a2', maxTicksLimit: 6 },
            title: { display: true, text: metric.title, color: '#9299a2' } },
          y: { grid: { display: false }, ticks: { color: '#c3c6cb', font: { size: 12 } }, border: { display: false } },
        },
        plugins: {
          legend: { display: false },
          tooltip: { backgroundColor: '#202328', titleColor: '#f5f5f7', bodyColor: '#c3c6cb',
            callbacks: {
              title: items => metricRows()[items[0].dataIndex].label,
              label: item => `${formatter.format(item.parsed.x)} ${metric.unit}`,
              afterLabel: item => {
                const row = metricRows()[item.dataIndex];
                return [...metric.detail(row), `Measured ${row.measurement_date} · ${row.release}`];
              },
            } },
        },
      },
    }));
  }

  function element(tag, content, className) {
    const node = document.createElement(tag);
    if (content !== undefined) node.textContent = content;
    if (className) node.className = className;
    return node;
  }

  function exactValues() {
    const wrapper = element('div', undefined, 'benchmark-records');
    for (const [index, row] of selected.entries()) {
      const record = element('section', undefined, 'benchmark-record');
      const heading = element('h3', row.label);
      heading.style.borderColor = pipelines[row.backend].color;
      record.append(heading);
      const fields = [
        ['Measured', `${row.measurement_date} · ${row.release}`],
        ['Speed', `${row.median_fps.toFixed(1)} fps (${row.min_fps.toFixed(1)}–${row.max_fps.toFixed(1)})`],
        ['VMAF / SSIM', `${row.vmaf.toFixed(3)} / ${row.ssim.toFixed(6)}`],
        ['File size', `${formatter.format(row.median_file_bytes)} bytes`],
        ['File bitrate', `${row.median_container_mbps.toFixed(6)} Mb/s`],
        ['Scored file', `${formatter.format(row.scored_output.file_bytes)} bytes · ${row.scored_output.container_mbps.toFixed(6)} Mb/s`],
        ['FFmpeg CPU time', `${row.median_cpu_seconds.toFixed(3)} seconds`],
      ];
      if (row.backend.startsWith('nvenc-')) {
        fields.push(
          ['GPU-board energy', `${row.median_gpu_board_joules.toFixed(3)} joules`],
          ['Average GPU-board power', `${row.median_gpu_board_average_watts.toFixed(3)} watts`],
          ['GPU-board efficiency', `${row.median_gpu_board_frames_per_joule.toFixed(3)} frames/joule`],
        );
      }
      if (row.backend === 'videotoolbox') {
        const energy = energySelected.find(item => item.backend === row.backend);
        fields.push(
          ['Mac-system energy', `${energy.median_joules.toFixed(3)} joules`],
          ['Average Mac-system power', `${energy.average_watts.toFixed(3)} watts`],
          ['Mac-system efficiency', `${energy.frames_per_joule.toFixed(3)} frames/joule`],
          ['Energy measured', `${energy.measurement_date} · ${energy.release}`],
          ['Energy run speed / VMAF', `${energy.median_fps.toFixed(1)} fps / ${energy.vmaf.toFixed(3)}`],
        );
      }
      const list = element('dl');
      for (const [name, value] of fields) list.append(element('dt', name), element('dd', value));
      record.append(list);
      wrapper.append(record);
    }
    document.querySelector('#benchmark-values').replaceChildren(wrapper);
  }

  function update() {
    const [fixture, codec, size] = controls.map(control => control.value);
    selected = data.rows.filter(row => row.fixture === fixture && row.codec === codec && row.size === size);
    if (selected.length !== Object.keys(pipelines).length || new Set(selected.map(row => row.backend)).size !== selected.length) throw new Error('Incomplete benchmark selection');
    const mac = data.videotoolbox_energy.rows.find(row => row.fixture === fixture && row.codec === codec && row.size === size);
    if (!mac) throw new Error('Missing Mac-system energy measurement');
    energySelected = [
      { ...mac, label: 'VideoToolbox (Mac system)', chart_label: 'VT · Mac system',
        median_joules: mac.median_mac_system_joules, average_watts: mac.median_mac_system_average_watts,
        frames_per_joule: mac.median_mac_system_frames_per_joule, power_scope: 'Mac system',
        measurement_date: data.videotoolbox_energy.date,
        release: `FFmpeg ${data.videotoolbox_energy.builds[0].version}` },
      ...selected.filter(row => row.backend.startsWith('nvenc-')).map(row => ({ ...row,
        chart_label: `${pipelines[row.backend].label} · GPU board`,
        median_joules: row.median_gpu_board_joules, average_watts: row.median_gpu_board_average_watts,
        frames_per_joule: row.median_gpu_board_frames_per_joule, power_scope: 'GPU board' })),
    ];
    document.querySelector('#benchmark-selection').textContent = controls.map(control => control.selectedOptions[0].textContent).join(' · ');
    document.querySelector('#benchmark-control-note').hidden = fixture !== 'smptebars';
    for (const [index, chart] of charts.entries()) {
      const metric = metrics[index];
      const rows = metric.id === 'energy' ? energySelected : selected;
      chart.data.labels = rows.map(row => row.chart_label || pipelines[row.backend].label);
      chart.data.datasets[0].backgroundColor = rows.map(row => pipelines[row.backend].color);
      chart.data.datasets[0].data = rows.map(row => row[metric.key]);
      chart.canvas.parentElement.style.height = `${Math.max(150, rows.length * 38 + 55)}px`;
      chart.canvas.setAttribute('aria-label', `${metric.title}: ${rows.map(row => `${row.label} ${formatter.format(row[metric.key])} ${metric.unit}`).join('; ')}. Exact values appear below.`);
      chart.update();
    }
    exactValues();
  }

  for (const control of controls) control.addEventListener('change', update);
  update();
})();
