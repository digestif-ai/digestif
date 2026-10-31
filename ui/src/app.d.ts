declare global {
  namespace App {
    interface Error {
      message: string;
    }
    /** Navigation state: the brief the writer drafted, carried from My brief into its edit form. */
    interface PageState {
      draft?: string;
    }
  }
}

export {};
