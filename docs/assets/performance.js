/* The charts and exact values share one measured dataset. */
(() => {
  const container = document.querySelector('#benchmark');
  const source = document.querySelector('#benchmark-data');
  if (!container || !source || !window.Chart) return;

  const data = JSON.parse(source.textContent);
  const controls = ['input', 'codec', 'size'].map(name => document.querySelector(`#benchmark-${name}`));
  const colors = ['#a4c8ff', '#b1b6be', '#d9b98f', '#c7b9f2', '#a6efc3'];
  const shortLabels = ['Intel VA-API', 'CPU fast', 'CPU medium', 'VT local', 'VT remote'];
  const formatter = new Intl.NumberFormat('en', { maximumFractionDigits: 2 });
  const charts = [];
  let selected = [];

  const metrics = [
    { id: 'speed', key: 'median_fps', unit: 'fps', title: 'Frames per second',
      detail: row => [`Run range: ${formatter.format(row.min_fps)}–${formatter.format(row.max_fps)} fps`, `${formatter.format(row.median_fps / 30)}× real time`] },
    { id: 'quality', key: 'vmaf', unit: 'VMAF', title: 'VMAF score', max: 100,
      detail: row => [`Scored file: ${formatter.format(row.scored_output.container_mbps)} Mb/s`, `SSIM: ${row.ssim.toFixed(6)}`] },
    { id: 'cpu', key: 'median_cpu_seconds', unit: 'CPU s', title: 'FFmpeg CPU seconds',
      detail: row => row.backend === 'videotoolbox-remote' ? ['Linux FFmpeg process only', 'Mac daemon excluded'] : ['Submitting FFmpeg process', 'CPU seconds are not watts'] },
  ];

  for (const metric of metrics) {
    charts.push(new Chart(document.querySelector(`#benchmark-${metric.id}`), {
      type: 'bar',
      data: { labels: shortLabels, datasets: [{ data: [], backgroundColor: colors, borderRadius: 4, barThickness: 22 }] },
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
              title: items => selected[items[0].dataIndex].label,
              label: item => `${formatter.format(item.parsed.x)} ${metric.unit}`,
              afterLabel: item => {
                const row = selected[item.dataIndex];
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
      heading.style.borderColor = colors[index];
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
    if (selected.length !== 5) throw new Error('Incomplete benchmark selection');
    document.querySelector('#benchmark-selection').textContent = controls.map(control => control.selectedOptions[0].textContent).join(' · ');
    document.querySelector('#benchmark-control-note').hidden = fixture !== 'smptebars';
    for (const [index, chart] of charts.entries()) {
      chart.data.datasets[0].data = selected.map(row => row[metrics[index].key]);
      chart.canvas.setAttribute('aria-label', `${metrics[index].title}: ${selected.map(row => `${row.label} ${formatter.format(row[metrics[index].key])} ${metrics[index].unit}`).join('; ')}. Exact values appear below.`);
      chart.update();
    }
    exactValues();
  }

  for (const control of controls) control.addEventListener('change', update);
  update();
})();
