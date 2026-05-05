import { createTemplateAction } from '@backstage/plugin-scaffolder-node';

const ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';

export const generateSuffixAction = () =>
  createTemplateAction<{ length?: number }>({
    id: 'whisperops:generate-suffix',
    description: 'Generate a random alphanumeric suffix for agent uniqueness',
    schema: {
      input: {
        type: 'object',
        properties: {
          length: {
            type: 'number',
            title: 'Suffix Length',
            description: 'Length of the generated suffix (default: 4)',
            default: 4,
          },
        },
      },
      output: {
        type: 'object',
        required: ['suffix'],
        properties: {
          suffix: {
            type: 'string',
            title: 'Generated Suffix',
            description: 'Random alphanumeric suffix',
          },
        },
      },
    },
    async handler(ctx) {
      const len = ctx.input.length ?? 4;
      let s = '';
      for (let i = 0; i < len; i++) {
        s += ALPHABET[Math.floor(Math.random() * ALPHABET.length)];
      }
      ctx.logger.info(`Generated suffix: ${s}`);
      ctx.output('suffix', s);
    },
  });
