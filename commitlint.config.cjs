const englishOnlyRule = (parsed) => {
  const message = parsed.raw
    .split('\n')
    .filter((line) => !line.startsWith('#'))
    .join('\n')
    .trim();

  return [
    /^[\x00-\x7F]*$/.test(message),
    'commit message must use English/ASCII characters only',
  ];
};

module.exports = {
  extends: ['@commitlint/config-conventional'],
  plugins: [
    {
      rules: {
        'english-only': englishOnlyRule,
      },
    },
  ],
  rules: {
    'english-only': [2, 'always'],
  },
};
