class OrzRingBufferProcessor extends AudioWorkletProcessor {
    constructor(options) {
        super();
        const config = options.processorOptions;
        this.control = new Int32Array(config.control);
        this.samples = new Float32Array(config.samples);
        this.capacityFrames = config.capacityFrames;
        this.channels = config.channels;
        this.generation = config.generation;
        this.ratio = config.sourceSampleRate / sampleRate;
        this.phase = 0;
    }

    process(_inputs, outputs) {
        const output = outputs[0];
        const frames = output[0].length;
        if (Atomics.load(this.control, 3) !== this.generation) return false;

        let read = Atomics.load(this.control, 1);
        const write = Atomics.load(this.control, 0);
        const available = write >= read ? write - read : this.capacityFrames - read + write;
        const producible = Math.min(frames, Math.floor(Math.max(0, available - 1) / this.ratio));

        for (let frame = 0; frame < producible; frame++) {
            const sourceFrame = Math.floor(this.phase);
            const fraction = this.phase - sourceFrame;
            const source = ((read + sourceFrame) % this.capacityFrames) * this.channels;
            const next = ((read + sourceFrame + 1) % this.capacityFrames) * this.channels;
            for (let channel = 0; channel < output.length; channel++) {
                const index = Math.min(channel, this.channels - 1);
                const a = this.samples[source + index];
                output[channel][frame] = a + (this.samples[next + index] - a) * fraction;
            }
            this.phase += this.ratio;
        }
        const consumed = Math.floor(this.phase);
        this.phase -= consumed;
        read = (read + consumed) % this.capacityFrames;
        Atomics.store(this.control, 1, read);
        if (producible < frames && Atomics.load(this.control, 2) === 1) Atomics.add(this.control, 4, 1);

        // state: 0=priming, 1=running, 2=end, 3=failed, 4=stopped
        return !(Atomics.load(this.control, 2) >= 2 && available <= 1);
    }
}

registerProcessor('orz-ring-buffer', OrzRingBufferProcessor);
